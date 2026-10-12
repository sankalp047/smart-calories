#!/bin/bash
# Known-answer tests for the app's math. Assertions live in *Test.swift files
# as top-level code, which swiftc only accepts in a file literally named
# main.swift — so each test is staged into a build directory under that name.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "== adaptive energy =="
mkdir -p "$BUILD/adaptive"
cp AdaptiveEnergyTest.swift "$BUILD/adaptive/main.swift"
swiftc -O "$BUILD/adaptive/main.swift" \
  ../SmartCalories/Services/AdaptiveEnergy.swift \
  ../SmartCalories/Models/UserProfile.swift \
  ../SmartCalories/Models/Food.swift \
  -o "$BUILD/adaptive_test"
"$BUILD/adaptive_test"

echo ""
echo "== energy math (heart rate) =="
mkdir -p "$BUILD/energy"
cp EnergyMathTest.swift "$BUILD/energy/main.swift"
swiftc -O "$BUILD/energy/main.swift" \
  ../SmartCalories/Services/EnergyMath.swift \
  ../SmartCalories/Services/CalibrationMath.swift \
  ../SmartCalories/Services/HeartSampleStore.swift \
  -o "$BUILD/energy_test"
"$BUILD/energy_test"
