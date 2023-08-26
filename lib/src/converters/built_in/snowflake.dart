import 'package:nyxx/nyxx.dart';

import '../../context/base.dart';
import '../../util/view.dart';
import '../converter.dart';

final RegExp _snowflakePattern = RegExp(r'^(?:<(?:@(?:!|&)?|#)([0-9]{15,20})>|([0-9]{15,20}))$');

Snowflake? convertSnowflake(StringView view, ContextData context) {
  String word = view.getQuotedWord();
  if (!_snowflakePattern.hasMatch(word)) {
    return null;
  }

  final RegExpMatch match = _snowflakePattern.firstMatch(word)!;

  // 1st group will catch mentions, second will catch raw IDs
  return Snowflake.parse(match.group(1) ?? match.group(2)!);
}

SelectMenuOptionBuilder snowflakeToMultiselectOption(Snowflake snowflake) =>
    SelectMenuOptionBuilder(
      label: snowflake.toString(),
      value: snowflake.toString(),
    );

ButtonBuilder snowflakeToButton(Snowflake snowflake) => ButtonBuilder(
      style: ButtonStyle.primary,
      label: snowflake.toString(),
      customId: '',
    );

/// A converter that converts input to a [Snowflake].
///
/// This converter will parse user mentions, member mentions, channel mentions or raw integers as
/// snowflakes.
const Converter<Snowflake> snowflakeConverter = Converter<Snowflake>(
  convertSnowflake,
  toMultiselectOption: snowflakeToMultiselectOption,
  toButton: snowflakeToButton,
);
