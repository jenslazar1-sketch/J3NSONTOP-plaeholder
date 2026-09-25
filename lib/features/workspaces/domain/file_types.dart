/// Coarse file categories used for icons and default actions.
enum FileCategory {
  folder('Folder'),
  link('Symbolic link'),
  text('Text'),
  code('Source / config'),
  data('Data table'),
  image('Image'),
  audio('Audio'),
  video('Video'),
  archive('Archive'),
  font('Font'),
  executable('Program / library'),
  other('File');

  const FileCategory(this.label);
  final String label;

  /// Whether the text editor is the natural way to open this file.
  bool get isTextual => this == text || this == code || this == data;
}

abstract final class FileTypes {
  static const Map<String, FileCategory> _byExt = {
    // text
    'txt': FileCategory.text, 'md': FileCategory.text, 'log': FileCategory.text, 'rtf': FileCategory.text,
    'nfo': FileCategory.text, 'readme': FileCategory.text,
    // code / config
    'json': FileCategory.code, 'json5': FileCategory.code, 'yaml': FileCategory.code, 'yml': FileCategory.code,
    'toml': FileCategory.code, 'ini': FileCategory.code, 'cfg': FileCategory.code, 'conf': FileCategory.code,
    'xml': FileCategory.code, 'html': FileCategory.code, 'htm': FileCategory.code, 'css': FileCategory.code,
    'js': FileCategory.code, 'ts': FileCategory.code, 'dart': FileCategory.code, 'py': FileCategory.code,
    'lua': FileCategory.code, 'sh': FileCategory.code, 'bat': FileCategory.code, 'ps1': FileCategory.code,
    'c': FileCategory.code, 'h': FileCategory.code, 'cpp': FileCategory.code, 'hpp': FileCategory.code,
    'cs': FileCategory.code, 'java': FileCategory.code, 'kt': FileCategory.code, 'rs': FileCategory.code,
    'go': FileCategory.code, 'properties': FileCategory.code, 'gitignore': FileCategory.code,
    'j3profile': FileCategory.code, 'shader': FileCategory.code, 'glsl': FileCategory.code,
    'hlsl': FileCategory.code, 'mcmeta': FileCategory.code, 'lang': FileCategory.code,
    // data
    'csv': FileCategory.data, 'tsv': FileCategory.data,
    // images
    'png': FileCategory.image, 'jpg': FileCategory.image, 'jpeg': FileCategory.image, 'gif': FileCategory.image,
    'bmp': FileCategory.image, 'webp': FileCategory.image, 'tga': FileCategory.image, 'dds': FileCategory.image,
    'ico': FileCategory.image, 'svg': FileCategory.image, 'psd': FileCategory.image, 'tif': FileCategory.image,
    'tiff': FileCategory.image,
    // audio / video
    'wav': FileCategory.audio, 'mp3': FileCategory.audio, 'ogg': FileCategory.audio, 'flac': FileCategory.audio,
    'm4a': FileCategory.audio, 'mp4': FileCategory.video, 'mkv': FileCategory.video, 'webm': FileCategory.video,
    'mov': FileCategory.video, 'avi': FileCategory.video,
    // archives
    'zip': FileCategory.archive, 'j3mod': FileCategory.archive, '7z': FileCategory.archive,
    'rar': FileCategory.archive, 'tar': FileCategory.archive, 'gz': FileCategory.archive,
    'pak': FileCategory.archive, 'jar': FileCategory.archive,
    // fonts
    'ttf': FileCategory.font, 'otf': FileCategory.font, 'woff': FileCategory.font, 'woff2': FileCategory.font,
    // programs
    'exe': FileCategory.executable, 'dll': FileCategory.executable, 'so': FileCategory.executable,
    'dylib': FileCategory.executable, 'apk': FileCategory.executable, 'msi': FileCategory.executable,
  };

  /// Lower-case extension without the dot ('' when none). Dotfiles such as
  /// `.gitignore` report their name as the extension.
  static String extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static FileCategory categoryOf(String name) => _byExt[extensionOf(name)] ?? FileCategory.other;

  /// Whether a name is hidden by convention (dotfiles).
  static bool isHidden(String name) => name.startsWith('.') && name != '.' && name != '..';
}
