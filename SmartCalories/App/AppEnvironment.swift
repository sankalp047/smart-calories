import Foundation
import Observation
import SwiftUI

/// Single source of truth for app state. Uses the Observation framework so
/// SwiftUI views re-render only on the properties they actually read.
@MainActor
@Observable
final class AppEnvironment {

    // MARK: - Stored state

    var profile: UserProfile?
    var settings = AppSettings()
    var calibration = CalibrationState()
    var diary: [DiaryEntry] = []
    var weights: [WeightEntry] = []
    var waterLog: [WaterEntry] = []
    var sessions: [WorkoutSession] = []
    /// The session currently being performed, if any.
    var activeSession: WorkoutSession?
    var favorites: [FavoriteFood] = []
    var recipes: [Recipe] = []

    /// Ingredients currently staged in the meal-prep calculator (session-only).
    var prepIngredients: [RecipeIngredient] = []
    var prepServings: Int = 1

    // MARK: - Services

    let foods = FoodRepository()
    let scale = ScaleService()
    let health = HealthService()
    let heart = HeartRateService()
    let ai = AIService()
    let notifications = NotificationService()
    let watch = PhoneConnectivity()
    let auth = AuthService()
    /// Cloud backup of the local Store blobs. Assigned in init (inline
    /// `lazy` fights the @Observable macro).
    let sync: SyncService
    /// Ships the raw heart-rate archive to the backend in the background.
    let heartShipper: HeartSampleShipper

    /// True while a fresh install is pulling the account's data back down.
    var isRestoring = false
    /// How many raw heart samples the last restore brought back, for the
    /// confirmation shown on the WHOOP screen.
    private(set) var restoredHeartSamples = 0

    // MARK: - Init

    init() {
        heartShipper = HeartSampleShipper(store: heart.samples)
        sync = SyncService(auth: auth)
        profile = Store.load(UserProfile.self, key: Store.Key.profile)
        settings = Store.load(AppSettings.self, key: Store.Key.settings) ?? AppSettings()
        diary = Store.load([DiaryEntry].self, key: Store.Key.diary) ?? []
        weights = Store.load([WeightEntry].self, key: Store.Key.weights) ?? []
        waterLog = Store.load([WaterEntry].self, key: Store.Key.water) ?? []
        sessions = Store.load([WorkoutSession].self, key: Store.Key.sessions) ?? []
        favorites = Store.load([FavoriteFood].self, key: Store.Key.favorites) ?? []
        recipes = Store.load([Recipe].self, key: Store.Key.recipes) ?? []
        calibration = Store.load(CalibrationState.self, key: Store.Key.calibration) ?? CalibrationState()

        scale.loadSavedConfig()
        if let profile {
            heart.configure(weightKg: profile.weightKg, age: profile.age,
                            isMale: profile.sex == .male,
                            maxHR: calibration.personalMaxHR)
        }
        Task { await foods.load() }

        // Watch sync: the phone owns the data, the watch asks for changes.
        watch.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .logWater(let ml):
                self.addWater(ml)
            case .logFavorite(let id):
                if let favorite = self.favorites.first(where: { $0.food.id == id }) {
                    self.log(DiaryEntry(food: favorite.food, grams: favorite.lastGrams))
                }
            }
        }
        // Live HR streamed from the Watch's workout session feeds the same
        // pipeline as the WHOOP; the service arbitrates between sources.
        watch.onHeartSample = { [weak self] bpm, date in
            self?.heart.ingestWatchSample(bpm: bpm, at: date)
        }
        watch.activate()
        heartShipper.start()
    }

    /// Re-read from disk. Siri/Shortcuts/widget intents mutate the same JSON
    /// while the app is backgrounded or not running, so the in-memory copy can
    /// be stale by the time the user looks at it again.
    func reloadFromDisk() {
        diary = Store.load([DiaryEntry].self, key: Store.Key.diary) ?? diary
        waterLog = Store.load([WaterEntry].self, key: Store.Key.water) ?? waterLog
        weights = Store.load([WeightEntry].self, key: Store.Key.weights) ?? weights
        favorites = Store.load([FavoriteFood].self, key: Store.Key.favorites) ?? favorites
    }

    // MARK: - Derived: today

    /// Learned energy expenditure — see `AdaptiveEnergy`. Recomputed on demand;
    /// the inputs are small enough that caching would cost more than it saves.
    var energy: AdaptiveEnergy.Result? {
        guard let profile else { return nil }
        return AdaptiveEnergy.estimate(profile: profile, diary: diary, weights: weights)
    }

    var calorieGoal: Double {
        if let override = settings.calorieGoalOverride { return Double(override) }
        guard let profile else { return 2000 }
        if let energy, energy.isAdaptive {
            return Double(AdaptiveEnergy.target(for: profile, result: energy))
        }
        return Double(profile.recommendedCalories)
    }

    // MARK: - Water

    func water(on day: Date) -> Double {
        waterLog.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.ml ?? 0
    }
    var waterToday: Double { water(on: Date()) }
    var waterTarget: Double { profile?.dailyWaterMl ?? 2500 }

    func addWater(_ ml: Double) {
        let today = Calendar.current.startOfDay(for: Date())
        if let index = waterLog.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) {
            waterLog[index].ml = max(0, waterLog[index].ml + ml)
        } else {
            waterLog.append(WaterEntry(date: today, ml: max(0, ml)))
        }
        Store.save(waterLog, key: Store.Key.water)
        scheduleCloudPush()
        Haptics.tap()
        pushToWatch()
        Task { await health.saveWater(ml: ml) }
    }

    func entries(on day: Date) -> [DiaryEntry] {
        diary.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date > $1.date }
    }

    var todayEntries: [DiaryEntry] { entries(on: Date()) }

    func calories(on day: Date) -> Double {
        entries(on: day).reduce(0) { $0 + $1.calories }
    }

    var caloriesToday: Double { calories(on: Date()) }
    var proteinToday: Double { todayEntries.reduce(0) { $0 + ($1.protein ?? 0) } }
    var fatToday: Double { todayEntries.reduce(0) { $0 + ($1.fat ?? 0) } }
    var carbsToday: Double { todayEntries.reduce(0) { $0 + ($1.carbs ?? 0) } }

    /// Everything the user has burned today, from whichever source knows most.
    ///
    /// HealthKit's total (active + basal) wins when an Apple Watch is feeding
    /// it. Without one, the floor is BMR prorated across the day so far plus
    /// exercise energy from a connected heart-rate monitor — so a WHOOP or
    /// chest-strap user gets a real number instead of the old flat zero.
    var burnedToday: Double {
        var sensorEstimate = calibratedSensorKcal
        if let profile {
            let elapsed = Date().timeIntervalSince(Calendar.current.startOfDay(for: Date()))
            sensorEstimate += profile.bmr * elapsed / 86_400
        }
        return max(health.today.totalEnergy, sensorEstimate)
    }

    // MARK: - Cross-device calibration

    /// Sensor exercise energy on the Watch's scale, once the factor is earned.
    var calibratedSensorKcal: Double {
        heart.todayActiveKcal * (calibration.energyScale ?? 1.0)
    }

    /// Re-learn the calibration from days when both devices were worn.
    /// Runs after each HealthKit refresh; cheap, and always derived from the
    /// full stored history rather than incrementally patched.
    func recalibrate() {
        guard let profile else { return }
        let dayKey = { (d: Date) in WeightEntry.dayKey(d) }

        // Days our sensor genuinely recorded (≥ ~35 min of samples).
        let ourDays = heart.dailySummaries.filter { $0.sampleCount > 2000 }
        let ourEnergy = Dictionary(ourDays.map { (dayKey($0.date), $0.activeKcal) },
                                   uniquingKeysWith: { a, _ in a })
        let ourRest = Dictionary(
            ourDays.filter { $0.minHR < 250 }.map { (dayKey($0.date), Double($0.minHR)) },
            uniquingKeysWith: { a, _ in a })

        // Pair by calendar day against the Watch series; rolling recency
        // window is inherent (the series spans 30 days).
        let energyPairs = health.dailyActiveEnergy.compactMap { day -> (Double, Double)? in
            guard let ours = ourEnergy[dayKey(day.date)] else { return nil }
            return (ours, day.value)
        }
        let rhrPairs = health.dailyRestingHR.compactMap { day -> (Double, Double)? in
            guard let ours = ourRest[dayKey(day.date)] else { return nil }
            return (ours, day.value)
        }

        // A nil result means "not enough paired data right now" — it must
        // never erase what was already learned. Absence of evidence is not
        // evidence the old factor was wrong.
        calibration.energyScale = CalibrationMath.energyScale(
            pairs: energyPairs.map { (ours: $0.0, watch: $0.1) })
            ?? calibration.energyScale
        calibration.restingHROffset = CalibrationMath.restingHROffset(
            pairs: rhrPairs.map { (ours: $0.0, apple: $0.1) })
            ?? calibration.restingHROffset
        if energyPairs.count > 0 { calibration.pairedEnergyDays = energyPairs.count }
        if rhrPairs.count > 0 { calibration.pairedRHRDays = rhrPairs.count }

        // Personal max from real training days on either device.
        let observedMaxes = ourDays.map(\.maxHR)
        let personal = CalibrationMath.personalMaxHR(
            observedDailyMaxes: observedMaxes, age: Double(profile.age))
        if personal > EnergyMath.predictedMaxHR(age: Double(profile.age)) {
            calibration.personalMaxHR = personal
        }

        calibration.updatedAt = Date()
        Store.save(calibration, key: Store.Key.calibration)
        scheduleCloudPush()
        heart.configure(weightKg: profile.weightKg, age: profile.age,
                        isMale: profile.sex == .male, maxHR: calibration.personalMaxHR)
    }

    /// 0–100 readiness. Baseline blends both devices onto one scale via the
    /// learned offset; HRV (Watch overnight SDNN) joins once present. Nil
    /// until there's a baseline and a reading today — never a made-up number.
    var readiness: Double? {
        guard let today = heart.dailySummaries.last,
              Calendar.current.isDateInToday(today.date),
              today.minHR < 250
        else { return nil }

        let cal = Calendar.current
        let ourPriors = heart.dailySummaries
            .filter { !cal.isDateInToday($0.date) && $0.minHR < 250 }
            .suffix(7).map { Double($0.minHR) }
        let applePriors = health.dailyRestingHR
            .filter { !cal.isDateInToday($0.date) }
            .suffix(7).map(\.value)
        let baseline = CalibrationMath.blendedRestingBaseline(
            ourRecent: Array(ourPriors), appleRecent: Array(applePriors),
            offset: calibration.restingHROffset)
            ?? heart.baselineRestingHR
        guard let baseline else { return nil }

        let corrected = Double(today.minHR) - (calibration.restingHROffset ?? 0)

        // HRV baseline: median of the Watch's overnight SDNN before today.
        let sdnnPriors = health.dailySDNN.filter { !cal.isDateInToday($0.date) }.map(\.value)
        let sdnnToday = health.dailySDNN.last.flatMap {
            cal.isDateInToday($0.date) ? $0.value : nil
        }
        let hrvBaseline = sdnnPriors.count >= 5 ? CalibrationMath.median(sdnnPriors) : nil

        return EnergyMath.readinessScore(
            restingHR: corrected,
            baselineRestingHR: baseline,
            sleepMinutes: health.lastNightSleepMinutes,
            hrvSDNN: sdnnToday, hrvBaseline: hrvBaseline
        )
    }

    /// Lower-bound estimate of daily unlogged intake, from the disagreement
    /// between the weight-derived TDEE and the sensor-derived floor. The two
    /// measurements are independent, which is what makes the gap meaningful.
    var unloggedIntakeEstimate: Double? {
        guard let profile, let energy, energy.isAdaptive, energy.confidence >= 0.6
        else { return nil }

        // Mean sensor exercise energy over days that actually had a monitor on.
        let sensorDays = heart.dailySummaries.filter { $0.sampleCount > 500 }
        guard sensorDays.count >= 5 else { return nil }
        let meanActive = sensorDays.reduce(0) { $0 + $1.activeKcal } / Double(sensorDays.count)
            * (calibration.energyScale ?? 1.0)

        let intakeDays = loggedDays.prefix(28)
        guard !intakeDays.isEmpty else { return nil }
        let meanIntake = intakeDays.reduce(0) { $0 + calories(on: $1) } / Double(intakeDays.count)

        return EnergyMath.unloggedIntakeLowerBound(
            adaptiveTDEE: energy.tdee, bmr: profile.bmr,
            meanLoggedIntake: meanIntake, meanSensorActiveKcal: meanActive
        )
    }

    var remainingToday: Double { calorieGoal - caloriesToday }

    /// Consecutive days with at least one entry, ending today or yesterday.
    var streak: Int {
        let cal = Calendar.current
        let days = Set(diary.map { cal.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        let today = cal.startOfDay(for: Date())
        var cursor: Date
        if days.contains(today) {
            cursor = today
        } else if let yesterday = cal.date(byAdding: .day, value: -1, to: today), days.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    /// Distinct logged days, newest first.
    var loggedDays: [Date] {
        let cal = Calendar.current
        return Array(Set(diary.map { cal.startOfDay(for: $0.date) })).sorted(by: >)
    }

    // MARK: - Mutations

    func log(_ entry: DiaryEntry) {
        diary.append(entry)
        persistDiary()
        Haptics.success()
        // Mirror into Apple Health so the data isn't trapped in this app.
        Task { await health.save(entry) }
    }

    /// Re-log everything from a previous day. The single biggest friction
    /// reducer in food tracking — most people eat variations of the same week.
    func copyDay(_ source: Date, to target: Date = Date()) {
        let cal = Calendar.current
        let sourceEntries = entries(on: source)
        guard !sourceEntries.isEmpty else { return }

        for entry in sourceEntries {
            // Keep the original time-of-day, moved onto the target date.
            let time = cal.dateComponents([.hour, .minute], from: entry.date)
            let newDate = cal.date(bySettingHour: time.hour ?? 12,
                                   minute: time.minute ?? 0, second: 0, of: target) ?? target
            diary.append(
                DiaryEntry(foodId: entry.foodId, foodName: entry.foodName,
                           grams: entry.grams, calories: entry.calories, date: newDate,
                           protein: entry.protein, fat: entry.fat, carbs: entry.carbs,
                           meal: entry.meal)
            )
        }
        persistDiary()
        Haptics.success()
    }

    /// The most recent day before `day` that actually has entries.
    func previousLoggedDay(before day: Date = Date()) -> Date? {
        let start = Calendar.current.startOfDay(for: day)
        return loggedDays.first { $0 < start }
    }

    func delete(_ entry: DiaryEntry) {
        diary.removeAll { $0.id == entry.id }
        persistDiary()
    }

    /// Everything the Watch face needs, in one small payload.
    var watchSnapshot: WatchSnapshot {
        WatchSnapshot(
            eaten: caloriesToday,
            goal: calorieGoal,
            burned: burnedToday,
            protein: proteinToday,
            proteinTarget: Double(profile?.proteinTargetG ?? 0),
            waterMl: waterToday,
            waterTarget: waterTarget,
            streak: streak,
            favorites: favorites.prefix(WatchSnapshot.maxFavorites).map {
                WatchFavorite(id: $0.food.id, name: $0.food.name,
                              grams: $0.lastGrams,
                              calories: $0.food.calories(forGrams: $0.lastGrams))
            },
            updatedAt: Date()
        )
    }

    func pushToWatch() { watch.push(watchSnapshot) }

    /// Schedule a cloud push. Debounced so a burst of edits (logging six
    /// foods in a row) becomes one upload rather than six.
    private var pushTask: Task<Void, Never>?

    func scheduleCloudPush() {
        guard auth.isSignedIn else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.sync.push()
        }
    }

    private func persistDiary() {
        Store.save(diary, key: Store.Key.diary)
        scheduleCloudPush()
        pushToWatch()
        WidgetBridge.publish(
            eaten: caloriesToday, goal: calorieGoal, burned: burnedToday
        )
        rescheduleCheckIn()
    }

    func saveProfile(_ p: UserProfile) {
        profile = p
        Store.save(p, key: Store.Key.profile)
        scheduleCloudPush()
        heart.configure(weightKg: p.weightKg, age: p.age, isMale: p.sex == .male)
        settings.hasCompletedOnboarding = true
        saveSettings()
    }

    func saveSettings() {
        Store.save(settings, key: Store.Key.settings)
        scheduleCloudPush()
    }

    // MARK: - Weight

    func logWeight(_ kg: Double, on date: Date = Date()) {
        let entry = WeightEntry(date: date, kg: kg)
        weights.removeAll { $0.id == entry.id }
        weights.append(entry)
        weights.sort { $0.date < $1.date }
        Store.save(weights, key: Store.Key.weights)
        scheduleCloudPush()

        // Recalculate the calorie target from the new bodyweight.
        if var p = profile {
            p.weightKg = kg
            saveProfile(p)
        }
        Haptics.success()
    }

    var latestWeight: WeightEntry? { weights.last }
    var weightChange: Double? {
        guard weights.count >= 2, let first = weights.first, let last = weights.last else { return nil }
        return last.kg - first.kg
    }

    // MARK: - Training

    var strength: StrengthHistory { StrengthHistory(sessions: sessions) }

    func startSession(plan: WorkoutPlan, day: WorkoutDay) {
        activeSession = WorkoutSession(planName: plan.name, dayTitle: day.title)
    }

    func logSet(exercise: String, reps: Int, weightKg: Double) {
        guard activeSession != nil, reps > 0 else { return }
        activeSession?.sets.append(SetLog(exercise: exercise, reps: reps, weightKg: weightKg))
        Haptics.tap()
    }

    func removeLastSet(of exercise: String) {
        guard let index = activeSession?.sets.lastIndex(where: { $0.exercise == exercise }) else { return }
        activeSession?.sets.remove(at: index)
    }

    /// Finish and persist. An empty session is discarded rather than cluttering
    /// history with a workout that never happened.
    func finishSession() {
        guard var session = activeSession else { return }
        activeSession = nil
        guard !session.sets.isEmpty else { return }
        session.finishedAt = Date()
        // Attach heart stats if a monitor was live during the session.
        session.heart = heart.endSessionWindow()
        sessions.append(session)
        Store.save(sessions, key: Store.Key.sessions)
        scheduleCloudPush()
        Haptics.success()
    }

    func discardSession() { activeSession = nil }

    func deleteSession(_ session: WorkoutSession) {
        sessions.removeAll { $0.id == session.id }
        Store.save(sessions, key: Store.Key.sessions)
        scheduleCloudPush()
    }

    var recentSessions: [WorkoutSession] {
        sessions.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Favorites

    func isFavorite(_ food: Food) -> Bool { favorites.contains { $0.food.id == food.id } }

    func toggleFavorite(_ food: Food, grams: Double) {
        if isFavorite(food) {
            favorites.removeAll { $0.food.id == food.id }
        } else {
            favorites.append(FavoriteFood(food: food, lastGrams: grams > 0 ? grams : 100))
        }
        Store.save(favorites, key: Store.Key.favorites)
        scheduleCloudPush()
    }

    // MARK: - Recipes / meal prep

    func saveRecipe(name: String) {
        guard !prepIngredients.isEmpty else { return }
        recipes.append(Recipe(name: name, ingredients: prepIngredients, servings: prepServings))
        Store.save(recipes, key: Store.Key.recipes)
        scheduleCloudPush()
    }

    func deleteRecipe(_ recipe: Recipe) {
        recipes.removeAll { $0.id == recipe.id }
        Store.save(recipes, key: Store.Key.recipes)
        scheduleCloudPush()
    }

    func loadIntoPrep(_ recipe: Recipe) {
        prepIngredients = recipe.ingredients
        prepServings = recipe.servings
    }

    var prepTotalCalories: Double { prepIngredients.reduce(0) { $0 + $1.calories } }
    var prepTotalGrams: Double { prepIngredients.reduce(0) { $0 + $1.grams } }
    var prepTotalProtein: Double { prepIngredients.reduce(0) { $0 + ($1.protein ?? 0) } }
    var prepTotalFat: Double { prepIngredients.reduce(0) { $0 + ($1.fat ?? 0) } }
    var prepTotalCarbs: Double { prepIngredients.reduce(0) { $0 + ($1.carbs ?? 0) } }
    private func perServing(_ t: Double) -> Double { prepServings > 0 ? t / Double(prepServings) : t }
    var prepPerServingCalories: Double { perServing(prepTotalCalories) }
    var prepPerServingGrams: Double { perServing(prepTotalGrams) }

    // MARK: - Notifications

    func rescheduleCheckIn() {
        notifications.scheduleAll(settings: settings,
                                  eaten: caloriesToday,
                                  goal: calorieGoal)
    }

    // MARK: - Account

    /// Sign in, then decide whether this is a restore or a first upload.
    func signIn() async {
        await auth.signIn()
        guard auth.isSignedIn else { return }
        await restoreOrSeedCloud()
    }

    /// Called at launch too: a Keychain refresh token survives reinstall, so
    /// the user is put straight back in without tapping anything.
    func restoreSessionIfPossible() async {
        await auth.restoreSession()
        guard auth.isSignedIn else { return }
        await restoreOrSeedCloud()
    }

    /// Pull the account's data down when this device has none, otherwise push
    /// what's here up. Local data is never overwritten silently.
    private func restoreOrSeedCloud() async {
        isRestoring = true
        defer { isRestoring = false }
        let hadLocalProfile = profile != nil
        let restored = await sync.pull(overwriteLocal: false)
        if !restored.isEmpty {
            reloadEverythingFromDisk()
        }
        // A device that already had data contributes it to the account.
        if hadLocalProfile || restored.isEmpty {
            await sync.push()
        }

        // Rebuild the raw heart archive from the account's server-side
        // history. The samples outlived the phone, so the chart should too.
        let importedSamples = await sync.restoreHeartArchive(into: heart.samples)
        if importedSamples > 0 {
            restoredHeartSamples = importedSamples
        }
    }

    func signOut() {
        auth.signOut()
    }

    /// Full re-read after a cloud restore rewrites the files underneath us.
    func reloadEverythingFromDisk() {
        profile = Store.load(UserProfile.self, key: Store.Key.profile)
        settings = Store.load(AppSettings.self, key: Store.Key.settings) ?? settings
        diary = Store.load([DiaryEntry].self, key: Store.Key.diary) ?? []
        weights = Store.load([WeightEntry].self, key: Store.Key.weights) ?? []
        waterLog = Store.load([WaterEntry].self, key: Store.Key.water) ?? []
        sessions = Store.load([WorkoutSession].self, key: Store.Key.sessions) ?? []
        favorites = Store.load([FavoriteFood].self, key: Store.Key.favorites) ?? []
        recipes = Store.load([Recipe].self, key: Store.Key.recipes) ?? []
        calibration = Store.load(CalibrationState.self, key: Store.Key.calibration) ?? calibration
        if let profile {
            heart.configure(weightKg: profile.weightKg, age: profile.age,
                            isMale: profile.sex == .male, maxHR: calibration.personalMaxHR)
        }
    }

    /// Refresh Health data and push the latest numbers to the widget.
    ///
    /// Restores prior HealthKit permission first, so a user who already granted
    /// access isn't asked to connect again on every launch.
    func refreshHealth() async {
        if !health.isAuthorized {
            await health.restoreAuthorization()
        }
        await health.refresh()
        // Fresh Watch series in hand — re-learn the cross-device calibration.
        recalibrate()
        WidgetBridge.publish(eaten: caloriesToday, goal: calorieGoal, burned: burnedToday)
    }
}
