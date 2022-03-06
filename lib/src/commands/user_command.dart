//  Copyright 2021 Abitofevrything and others.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import 'dart:async';

import 'package:nyxx_commands/nyxx_commands.dart';
import 'package:nyxx_commands/src/util/mixins.dart';

class UserCommand
    with ParentMixin<UserContext>, CheckMixin<UserContext>, OptionsMixin<UserContext>
    implements ICommand<UserContext> {
  @override
  final String name;

  @override
  final Function(UserContext) execute;

  final StreamController<UserContext> _preCallController = StreamController.broadcast();
  final StreamController<UserContext> _postCallController = StreamController.broadcast();

  @override
  late final Stream<UserContext> onPreCall = _preCallController.stream;

  @override
  late final Stream<UserContext> onPostCall = _postCallController.stream;

  @override
  final CommandOptions options;

  UserCommand(
    this.name,
    this.execute, {
    Iterable<AbstractCheck> checks = const [],
    this.options = const CommandOptions(),
  }) {
    for (final check in checks) {
      this.check(check);
    }
  }

  @override
  Future<void> invoke(IContext context) async {
    if (context is! UserContext) {
      return;
    }

    for (final check in checks) {
      if (!await check.check(context)) {
        throw CheckFailedException(check, context);
      }
    }

    _preCallController.add(context);

    try {
      await execute(context);
    } on Exception catch (e) {
      throw UncaughtException(e, context);
    }

    _postCallController.add(context);
  }
}
