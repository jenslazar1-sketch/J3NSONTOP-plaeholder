import 'package:flutter/material.dart';

import '../../core/tools/tool_definition.dart';
import 'asset_lab_commands.dart';
import 'presentation/asset_lab_landing.dart';
import 'presentation/atlas_packer/atlas_packer_page.dart';
import 'presentation/color_lab/color_lab_page.dart';
import 'presentation/icon_export/icon_export_page.dart';
import 'presentation/image_studio/image_studio_page.dart';
import 'presentation/sprite_sheet/sprite_sheet_page.dart';

/// Asset Lab: image studio, sprite sheets, atlas packing, colours and app
/// icons. All image work is pure Dart (package:image) in background isolates.
final FeatureModule assetLabModule = FeatureModule(
  id: 'asset_lab',
  tools: [
    ToolDefinition(
      id: 'assets.image',
      name: 'Image Studio',
      section: ToolSection.assetLab,
      description: 'Inspect, resize, crop, rotate and flip images non-destructively, then export to PNG, JPEG, WebP...',
      icon: Icons.photo_filter_outlined,
      keywords: const [
        'image',
        'picture',
        'photo',
        'resize',
        'scale',
        'crop',
        'rotate',
        'flip',
        'mirror',
        'convert',
        'png',
        'jpeg',
        'jpg',
        'webp',
        'tga',
        'bmp',
        'tiff',
        'exif',
        'metadata',
        'texture',
      ],
      builder: (_) => const ImageStudioPage(),
    ),
    ToolDefinition(
      id: 'assets.sprites',
      name: 'Sprite Sheet',
      section: ToolSection.assetLab,
      description: 'Cut sprite sheets on a grid, preview the animation and export frames or an animated GIF.',
      icon: Icons.grid_on,
      keywords: const [
        'sprite',
        'spritesheet',
        'sheet',
        'frames',
        'slice',
        'split',
        'animation',
        'gif',
        'tiles',
        'tileset',
        'pixel art',
        'fps',
      ],
      builder: (_) => const SpriteSheetPage(),
    ),
    ToolDefinition(
      id: 'assets.atlas',
      name: 'Atlas Packer',
      section: ToolSection.assetLab,
      description: 'Pack images into a texture atlas PNG with a validated j3atlas JSON index.',
      icon: Icons.dashboard_customize_outlined,
      keywords: const ['atlas', 'texture atlas', 'pack', 'packer', 'maxrects', 'spritesheet', 'bin packing', 'json'],
      builder: (_) => const AtlasPackerPage(),
    ),
    ToolDefinition(
      id: 'assets.color',
      name: 'Color Lab',
      section: ToolSection.assetLab,
      description: 'HSV picker, HEX/RGB/HSL/HSV conversion, WCAG contrast, eyedropper and saved palettes.',
      icon: Icons.palette_outlined,
      keywords: const [
        'color',
        'colour',
        'picker',
        'hex',
        'rgb',
        'hsl',
        'hsv',
        'contrast',
        'wcag',
        'accessibility',
        'eyedropper',
        'palette',
        'gpl',
        'css',
      ],
      builder: (_) => const ColorLabPage(),
    ),
    ToolDefinition(
      id: 'assets.icons',
      name: 'App Icon Export',
      section: ToolSection.assetLab,
      description: 'Generate and verify Android, Google Play, iOS and Windows app icons from one artwork.',
      icon: Icons.apps_outlined,
      keywords: const [
        'icon',
        'app icon',
        'launcher',
        'mipmap',
        'adaptive',
        'android',
        'ios',
        'appiconset',
        'windows',
        'ico',
        'favicon',
        'play store',
      ],
      builder: (_) => const IconExportPage(),
    ),
  ],
  landings: [SectionLanding(ToolSection.assetLab, (_) => const AssetLabLanding())],
  commands: const [WcagCommand(), ColorFormatCommand(), ImageInfoCommand()],
);
