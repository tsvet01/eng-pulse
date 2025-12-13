# Eng Pulse App Icon Specifications

## Design Requirements

### Main Icon (`app_icon.png`)
- **Size**: 1024x1024 pixels (will be automatically scaled)
- **Format**: PNG with transparency support
- **Background**: Gradient from #6366F1 (top-left) to #4F46E5 (bottom-right)
- **Corner radius**: 24% (approximately 246px at 1024x1024)
- **Foreground**: White bolt/lightning icon centered

### Adaptive Icon Foreground (`app_icon_foreground.png`)
- **Size**: 1024x1024 pixels
- **Format**: PNG with transparency
- **Content**: White bolt icon only (no background)
- **Icon padding**: Leave ~30% padding for adaptive icon safe zone

## Color Palette
- Primary Purple: #6366F1 (RGB: 99, 102, 241)
- Accent Indigo: #4F46E5 (RGB: 79, 70, 229)
- Icon Color: #FFFFFF (White)

## Icon Symbol
- Lightning bolt / "bolt_rounded" icon
- Simple, recognizable silhouette
- Represents speed, energy, and daily engineering insights

## Quick Generation Options

### Option 1: Use Figma/Sketch
1. Create 1024x1024 canvas
2. Add rounded rectangle with gradient fill
3. Place bolt icon from Material Icons
4. Export as PNG

### Option 2: Use Online Tools
- Canva (free): Create with bolt icon template
- IconKitchen (Android icons): https://icon.kitchen
- AppIcon.co: Generate all sizes from one image

### Option 3: Command Line (ImageMagick)
```bash
# If you have the raw icon ready
convert app_icon_source.png -resize 1024x1024 app_icon.png
```

## After Creating Icons

Run the following command to generate all platform-specific icons:
```bash
flutter pub get
dart run flutter_launcher_icons
```

This will generate:
- Android: mipmap-hdpi, mipmap-mdpi, mipmap-xhdpi, mipmap-xxhdpi, mipmap-xxxhdpi
- iOS: AppIcon.appiconset with all required sizes
