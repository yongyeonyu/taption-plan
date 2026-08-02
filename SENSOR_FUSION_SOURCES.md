# Movement sensor fusion references

Taption Plan's movement classifier is implemented in this repository. No
third-party source file or machine-learning model is copied into the app.

## GitHub references

- [sobri909/LocoKit2](https://github.com/sobri909/LocoKit2) (MPL-2.0)
  - `LocomotionSample`: separates GPS speed/accuracy, cadence, acceleration,
    altitude, and contextual features.
  - `StepsMonitor`: prefers live `CMPedometerData.currentCadence`, with a
    step-count-over-duration fallback.
  - `AccelerometerSampler`: classifies a time window using acceleration mean
    and standard deviation instead of one instantaneous sample.
  - `StationaryStateDetector`: rejects low-quality GPS and uses a window of
    weighted speed statistics.
  - `UndergroundDetector`: treats sustained loss of valid GPS velocity and
    poor horizontal accuracy as an underground regime, not a single-point
    subway decision.
- [sobri909/LocoKit](https://github.com/sobri909/LocoKit) (LGPL-3.0)
  - Documents the important limitation that vehicle vibration can be counted
    as false pedometer steps.
  - Documents that specific transport modes need local context and should
    fall back to a generic low-confidence transport result when evidence is
    insufficient.
- [degtiarev/MotionCollector](https://github.com/degtiarev/MotionCollector) (MIT)
  - Shows a Watch/iPhone collection pipeline for accelerometer and gyroscope
    windows, with session IDs kept alongside exported samples.
- [WWDCNotes Core Motion overview](https://github.com/WWDCNotes/Content/blob/main/content/notes/wwdc23/10179.md)
  - Confirms the Watch accelerometer, gyroscope, magnetometer, and barometer
    are intended to be fused; its batched-sensor notes support windowed
    features instead of per-sample UI updates.
- [Sweefties WatchOS Core Motion/CMPedometer example](https://github.com/Sweefties/WatchOS2-NewAPI-CoreMotion-CMPedometer-Example)
  - Demonstrates Watch-side pedometer, cadence, pace, distance, and floor
    readings that complement the accelerometer window.

## Apple platform references

- [Core Motion](https://developer.apple.com/documentation/coremotion/)
- [CMDeviceMotion](https://developer.apple.com/documentation/coremotion/cmdevicemotion)
- [CMMotionActivity](https://developer.apple.com/documentation/coremotion/cmmotionactivity)
- [CMPedometer](https://developer.apple.com/documentation/coremotion/cmpedometer)
- [Core Location](https://developer.apple.com/documentation/corelocation)

## Taption Plan implementation decisions

- Persist GPS speed and course accuracy with each reading and exclude poor
  fixes or obvious speed spikes from classification.
- Persist live pace and cadence along with step count and walking/running
  distance.
- Aggregate high-frequency accelerometer and gyroscope data into sample count,
  mean, standard deviation, and peak features for each archive interval.
- Persist the processed magnetometer vector and heading for future classifier
  calibration, without treating magnetic changes alone as a travel mode.
- Use Apple Watch workouts as high-confidence ground truth, but treat ordinary
  iPhone and Apple Watch step counts as supporting evidence because vibration
  can produce false steps.
- Require combined GPS, altitude, rail-route, station, and GPS-loss evidence
  before selecting subway. Sensors alone do not reliably distinguish a bus,
  taxi, and private car, so those modes retain route, context, and user
  correction requirements.
- For subway candidates, combine a sustained GPS-loss/altitude-down window,
  low step cadence, rail speed or repeated-stop context, and Apple Watch
  three-axis acceleration standard deviation plus jerk. A single drop in GPS
  or a single acceleration spike never creates a subway segment.

## Activity behavior references

- [Aminoid/react-native-activity-recognition](https://github.com/Aminoid/react-native-activity-recognition/blob/master/ios/RNActivityRecognition.m)
  - Uses `CMMotionActivity` to expose passive iPhone states: stationary,
    walking, running, cycling, automotive and unknown.
- [georgegreenoflondon/HKWorkoutActivityType-Descriptions](https://github.com/georgegreenoflondon/HKWorkoutActivityType-Descriptions)
  - Provides a readable catalog for Apple Watch/HealthKit workout types. The
    app maps the iOS SDK catalog to Korean names and keeps measured intervals.

Core Motion records remain immutable. A passive interval is suppressed when a
HealthKit/Watch workout or explicit tracking session covers it; unsupported
sports are not inferred without a Watch workout record.
