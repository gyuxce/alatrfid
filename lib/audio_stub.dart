// Stub implementation for non-web platforms (Android/iOS)
// This file is used via conditional import when dart:js is not available.

void playWebBeepSound() {
  // No-op: On mobile, HapticFeedback is used instead (handled in main.dart)
}
