#!/bin/bash
echo "Installing Flutter..."
git clone https://github.com/flutter/flutter.git -b stable --depth 1
export PATH="$PATH:`pwd`/flutter/bin"
echo "Flutter installed."

echo "Enabling Web..."
flutter config --enable-web

echo "Getting dependencies..."
flutter pub get

echo "Building for Web..."
flutter build web --release --web-renderer html
