import 'package:PiliPlus/services/dafeiyu/models.dart';

/// Pure L0 rule evaluation, adapted from ybyz2/bilibili-dafeiyu-blocker.
/// https://github.com/ybyz2/bilibili-dafeiyu-blocker
class DfyJudge {
  DfyJudge(this.config)
    : _words = _literalWords(config.words),
      _names = _literalWords(config.names);

  final DfyConfig config;
  final RegExp? _words;
  final RegExp? _names;
  static final _name = RegExp('肥[鱼魚]');
  static final _brand = _literalWords([
    '大肥鱼',
    '肥鱼',
    '鲸鱼',
    '大肥鲸',
    '鲸鱼娘',
    '本鲸',
    '本鱼',
    '本肥鱼',
    '主人',
  ])!;
  static final _single = RegExp('[鱼魚鲸鯨]');
  static final _killPunctuation = RegExp(r'[：；「」\u2014\u2015\u2500]|--');
  static final _quote = RegExp(r'^回复\s*@[\s\S]{0,40}?\s*[:：]\s*');
  static final _mention = RegExp(
    r'(?:^|[^\w.+-])@[\w\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af-]',
  );

  static RegExp? _literalWords(List<String> words) {
    if (words.isEmpty) return null;
    final patterns = words.map((word) {
      final out = StringBuffer();
      for (final rune in word.runes) {
        final ch = String.fromCharCode(rune);
        // Only these two characters have upstream simplified/traditional variants.
        out.write(switch (ch) {
          '鱼' || '魚' => '[鱼魚]',
          '鲸' || '鯨' => '[鲸鯨]',
          _ => RegExp.escape(ch),
        });
      }
      return out.toString();
    });
    return RegExp(patterns.join('|'), caseSensitive: false);
  }

  static String stripQuotePrefix(String message) =>
      message.replaceFirst(_quote, '');

  bool isBlocked(String name, String message) => reason(name, message) != null;

  String? reason(String name, String message) {
    if (!config.enabled) return null;
    if (_names?.hasMatch(name) ?? false) return 'customName';
    if (_name.hasMatch(name)) return 'name';
    if (_words?.hasMatch(message) ?? false) return 'customWord';
    final body = stripQuotePrefix(message);
    final mentioned = body.contains('@') && _mention.hasMatch(body);
    if (config.tier == DfyTier.atonly) return mentioned ? 'mention' : null;
    if (_brand.hasMatch(message)) return 'brand';
    if (config.tier == DfyTier.cup) return null;
    if (mentioned) return 'mention';
    if (config.tier == DfyTier.standard) return null;
    if (_single.hasMatch(message)) return 'character';
    if (_killPunctuation.hasMatch(message)) return 'punctuation';
    return null;
  }
}
