import 'dart:async';
import 'dart:math';

import 'package:nyxx/nyxx.dart';

import 'package:runtime_type/runtime_type.dart';

import '../checks/checks.dart';
import '../commands.dart';
import '../commands/chat_command.dart';
import '../commands/interfaces.dart';
import '../commands/options.dart';
import '../context/base.dart';
import '../context/component_context.dart';
import '../context/modal_context.dart';
import '../converters/converter.dart';
import '../errors.dart';
import '../util/util.dart';
import '../util/view.dart';

mixin ParentMixin<T extends CommandContext> implements CommandRegisterable<T> {
  CommandGroup<CommandContext>? _parent;

  @override
  CommandGroup<CommandContext>? get parent => _parent;

  @override
  set parent(CommandGroup<CommandContext>? parent) {
    if (_parent != null) {
      throw CommandRegistrationError('Cannot register command "$name" again');
    }
    _parent = parent;
  }
}

mixin CheckMixin<T extends CommandContext> on CommandRegisterable<T> implements Checked {
  final List<AbstractCheck> _checks = [];

  @override
  Iterable<AbstractCheck> get checks => [...?parent?.checks, ..._checks];

  @override
  void check(AbstractCheck check) {
    _checks.add(check);

    for (final preCallHook in check.preCallHooks) {
      onPreCall.listen(preCallHook);
    }

    for (final postCallHook in check.postCallHooks) {
      onPostCall.listen(postCallHook);
    }
  }
}

mixin OptionsMixin<T extends CommandContext> on CommandRegisterable<T> implements Options {
  @override
  CommandOptions get resolvedOptions {
    if (parent == null) {
      return options;
    }

    CommandOptions parentOptions = parent is CommandRegisterable
        ? (parent as CommandRegisterable).resolvedOptions
        : parent!.options;

    CommandType? parentType = parentOptions.type;
    if (parent is CommandsPlugin) {
      if ((parent as CommandsPlugin).prefix == null && parentType == CommandType.all) {
        parentType = CommandType.slashOnly;
      }
    }

    return CommandOptions(
      autoAcknowledgeInteractions:
          options.autoAcknowledgeInteractions ?? parentOptions.autoAcknowledgeInteractions,
      acceptBotCommands: options.acceptBotCommands ?? parentOptions.acceptBotCommands,
      acceptSelfCommands: options.acceptSelfCommands ?? parentOptions.acceptSelfCommands,
      defaultResponseLevel: options.defaultResponseLevel ?? parentOptions.defaultResponseLevel,
      type: options.type ?? parentType,
      autoAcknowledgeDuration:
          options.autoAcknowledgeDuration ?? parentOptions.autoAcknowledgeDuration,
      caseInsensitiveCommands:
          options.caseInsensitiveCommands ?? parentOptions.caseInsensitiveCommands,
    );
  }
}

mixin InteractiveMixin implements InteractiveContext, ContextData {
  @override
  InteractiveContext? get parent => _parent;

  // Must narrow type to use [_nearestCommandContext].
  InteractiveMixin? _parent;

  @override
  InteractiveContext? get delegate => _delegate;
  InteractiveContext? _delegate;

  @override
  InteractiveContext get latestContext => delegate?.latestContext ?? this;

  CommandContext get _nearestCommandContext {
    if (this is CommandContext) {
      return this as CommandContext;
    }

    if (parent == null) {
      // This generally happens when a context is created directly from the plugin's context manager
      // and not from an existing context inside a command, which messes with functionality like
      // parsing which requires an ICommandContext to invoke converters.
      throw CommandsError(
        'Cannot use command functionality in a context created outside of a command',
      );
    }

    return _parent!._nearestCommandContext;
  }

  @override
  Future<ButtonComponentContext> awaitButtonPress(ComponentId componentId) async {
    if (delegate != null) {
      return delegate!.awaitButtonPress(componentId);
    }

    try {
      ButtonComponentContext context = await commands.eventManager.nextButtonEvent(componentId);

      context._parent = this;
      _delegate = context;

      return context;
    } on TimeoutException catch (e, s) {
      throw InteractionTimeoutException(
        'Timed out waiting for button press on component $componentId',
        _nearestCommandContext,
      )..stackTrace = s;
    }
  }

  @override
  Future<SelectMenuContext<T>> awaitSelection<T>(
    ComponentId componentId, {
    Converter<T>? converterOverride,
  }) async {
    if (delegate != null) {
      return delegate!.awaitSelection(
        componentId,
        converterOverride: converterOverride,
      );
    }

    SelectMenuContext<List<String>> rawContext =
        await commands.eventManager.nextSelectMenuEvent(componentId);

    SelectMenuContext<T> context = await commands.contextManager.createSelectMenuContext(
      rawContext.interaction,
      await parse(
        commands,
        _nearestCommandContext,
        StringView(rawContext.selected.single, isRestBlock: true),
        RuntimeType<T>(),
      ),
    );

    context._parent = this;
    _delegate = context;

    return context;
  }

  @override
  Future<SelectMenuContext<List<T>>> awaitMultiSelection<T>(
    ComponentId componentId, {
    Converter<T>? converterOverride,
  }) async {
    if (delegate != null) {
      return delegate!.awaitMultiSelection(
        componentId,
        converterOverride: converterOverride,
      );
    }

    SelectMenuContext<List<String>> rawContext =
        await commands.eventManager.nextSelectMenuEvent(componentId);

    SelectMenuContext<List<T>> context = await commands.contextManager.createSelectMenuContext(
      rawContext.interaction,
      await Future.wait(rawContext.selected.map(
        (value) => parse(
          commands,
          rawContext,
          StringView(value, isRestBlock: true),
          RuntimeType<T>(),
        ),
      )),
    );

    context._parent = this;
    _delegate = context;

    return context;
  }

  @override
  Future<ButtonComponentContext> getButtonPress(Message message) async {
    if (_delegate != null) {
      return _delegate!.getButtonPress(message);
    }

    final componentIds = message.components
            ?.expand(
                (component) => component is ActionRowComponent ? component.components : [component])
            .whereType<ButtonComponent>()
            .where((element) => element.customId != null)
            .map((component) => ComponentId.parse(component.customId!))
            .toList() ??
        [];

    if (componentIds.any((element) => element == null)) {
      throw UncaughtCommandsException(
        'Buttons in getButtonPress must have an ID set with ComponentId.generate()',
        _nearestCommandContext,
      );
    }

    int remaining = componentIds.length;
    Completer<ButtonComponentContext> completer = Completer();

    for (final id in componentIds) {
      commands.eventManager.nextButtonEvent(id!).then((context) {
        if (completer.isCompleted) {
          return;
        }

        completer.complete(context);
      }).catchError((Object error, StackTrace stackTrace) {
        remaining--;

        if (remaining == 0 && !completer.isCompleted) {
          // All the futures failed with an exception, throw the latest one back to the user
          if (error is TimeoutException) {
            error = InteractionTimeoutException(
              'Timed out waiting for button press on message ${message.id}',
              _nearestCommandContext,
            );
          }

          completer.completeError(error, stackTrace);
        }
      });
    }

    ButtonComponentContext context = await completer.future;

    context._parent = this;
    _delegate = context;

    return context;
  }

  @override
  Future<T> getButtonSelection<T>(
    List<T> values,
    MessageBuilder builder, {
    Map<T, ButtonStyle>? styles,
    bool authorOnly = true,
    ResponseLevel? level,
    Duration? timeout,
    FutureOr<ButtonBuilder> Function(T)? toButton,
    Converter<T>? converterOverride,
  }) async {
    if (_delegate != null) {
      return _delegate!.getButtonSelection(
        values,
        builder,
        authorOnly: authorOnly,
        converterOverride: converterOverride,
        level: level,
        styles: styles,
        timeout: timeout,
        toButton: toButton,
      );
    }

    assert(
      toButton == null || converterOverride == null,
      'Cannot specify both toButton and converterOverride.',
    );

    toButton ??= converterOverride?.toButton;
    toButton ??= commands.getConverter(RuntimeType<T>())?.toButton;

    if (toButton == null) {
      throw UncaughtCommandsException(
        'No suitable method found for converting $T to ButtonBuilder.',
        _nearestCommandContext,
      );
    }

    Map<ComponentId, T> idToValue = {};

    List<ButtonBuilder> buttons = await Future.wait(values.map((value) async {
      ButtonBuilder builder = await toButton!(value);
      ButtonStyle? style = styles?[value];

      ComponentId id = ComponentId.generate(
        expirationTime: timeout,
        allowedUser: authorOnly ? user.id : null,
      );

      idToValue[id] = value;

      // We have to copy since the fields on ButtonBuilder are final.
      return ButtonBuilder(
        style: style ?? builder.style,
        label: builder.label,
        emoji: builder.emoji,
        customId: id.toString(),
        isDisabled: builder.isDisabled,
      );
    }));

    final activeComponentRows = [...?builder.components];
    final disabledComponentRows = [...?builder.components];

    while (buttons.isNotEmpty) {
      // Max 5 buttons per row
      int count = min(5, buttons.length);

      ActionRowBuilder activeRow = ActionRowBuilder(components: []);
      ActionRowBuilder disabledRow = ActionRowBuilder(components: []);

      for (final button in buttons.take(count)) {
        activeRow.components.add(button);

        disabledRow.components.add(
          ButtonBuilder(
            style: button.style,
            label: button.label,
            emoji: button.emoji,
            customId: button.customId,
            isDisabled: true,
          ),
        );
      }

      activeComponentRows.add(activeRow);
      disabledComponentRows.add(disabledRow);

      buttons.removeRange(0, count);
    }

    builder.components = activeComponentRows;
    final message = await respond(builder, level: level);

    final listeners =
        idToValue.keys.map((id) => commands.eventManager.nextButtonEvent(id)).toList();

    try {
      ButtonComponentContext context = await Future.any(listeners);

      context._parent = this;
      _delegate = context;

      return idToValue[context.parsedComponentId]!;
    } on TimeoutException catch (e, s) {
      throw InteractionTimeoutException(
        'Timed out waiting for button selection',
        _nearestCommandContext,
      )..stackTrace = s;
    } finally {
      for (final id in idToValue.keys) {
        commands.eventManager.stopListeningFor(id);
      }

      await message.update(
        MessageUpdateBuilder(components: disabledComponentRows),
      );
    }
  }

  @override
  Future<bool> getConfirmation(
    MessageBuilder builder, {
    Map<bool, String> values = const {true: 'Yes', false: 'No'},
    Map<bool, ButtonStyle> styles = const {true: ButtonStyle.success, false: ButtonStyle.danger},
    bool authorOnly = true,
    ResponseLevel? level,
    Duration? timeout,
  }) =>
      getButtonSelection(
        [true, false],
        builder,
        toButton: (value) => ButtonBuilder(
          style: ButtonStyle.primary,
          label: values[value] ?? (value ? 'Yes' : 'No'),
          customId: '',
        ),
        styles: styles,
        authorOnly: authorOnly,
        level: level,
        timeout: timeout,
      );

  @override
  Future<T> getSelection<T>(
    List<T> choices,
    MessageBuilder builder, {
    ResponseLevel? level,
    Duration? timeout,
    bool authorOnly = true,
    FutureOr<SelectMenuOptionBuilder> Function(T)? toMultiSelect,
    Converter<T>? converterOverride,
  }) async {
    if (_delegate != null) {
      return _delegate!.getSelection(
        choices,
        builder,
        authorOnly: authorOnly,
        converterOverride: converterOverride,
        level: level,
        timeout: timeout,
        toMultiSelect: toMultiSelect,
      );
    }

    assert(
      toMultiSelect == null || converterOverride == null,
      'Cannot specify both toMultiSelect and converterOverride',
    );

    toMultiSelect ??= converterOverride?.toMultiselectOption;
    toMultiSelect ??= commands.getConverter(RuntimeType<T>())?.toMultiselectOption;

    if (toMultiSelect == null) {
      throw UncaughtCommandsException(
        'No suitable method for converting $T to MultiselectOptionBuilder found',
        _nearestCommandContext,
      );
    }

    Map<String, T> idToValue = {};
    List<SelectMenuOptionBuilder> options = await Future.wait(choices.map(
      (value) async {
        SelectMenuOptionBuilder builder = await toMultiSelect!(value);
        idToValue[builder.value] = value;
        return builder;
      },
    ));

    SelectMenuOptionBuilder prevPageOption = SelectMenuOptionBuilder(
      label: 'Previous page',
      value: ComponentId.generate().toString(),
    );

    SelectMenuOptionBuilder nextPageOption = SelectMenuOptionBuilder(
      label: 'Next page',
      value: ComponentId.generate().toString(),
    );

    SelectMenuContext<List<String>>? context;
    int currentOffset = 0;

    SelectMenuBuilder? menu;
    Message? message;

    try {
      do {
        bool hasPreviousPage = currentOffset != 0;
        int itemsPerPage = hasPreviousPage ? 24 : 25;
        bool hasNextPage = currentOffset + itemsPerPage < options.length;

        if (hasNextPage) {
          itemsPerPage -= 1;
        }

        final menuId = ComponentId.generate(
          expirationTime: timeout,
          allowedUser: authorOnly ? user.id : null,
        );

        menu = SelectMenuBuilder(
          type: MessageComponentType.stringSelect,
          customId: menuId.toString(),
          options: [
            if (hasPreviousPage) prevPageOption,
            ...options.skip(currentOffset).take(itemsPerPage),
            if (hasNextPage) nextPageOption,
          ],
        );

        ActionRowBuilder row = ActionRowBuilder(components: [menu]);
        if (context == null) {
          // This is the first time we're sending a message, just append the component row.
          (builder.components ??= []).add(row);

          message = await respond(builder, level: level);
        } else {
          // On later iterations, replace the last row with our newly created one.
          List<ActionRowBuilder> rows = builder.components!;

          rows[rows.length - 1] = row;

          await context.respond(
            builder,
            level: (level ?? _nearestCommandContext.command.resolvedOptions.defaultResponseLevel)!
                .copyWith(preserveComponentMessages: false),
          );
        }

        context = await commands.eventManager.nextSelectMenuEvent(menuId);

        if (context.selected.single == nextPageOption.value) {
          currentOffset += itemsPerPage;
        } else if (context.selected.single == prevPageOption.value) {
          currentOffset -= itemsPerPage;
        }
      } while (context.selected.single == nextPageOption.value ||
          context.selected.single == prevPageOption.value);

      context._parent = this;
      _delegate = context;

      final result = idToValue[context.selected.single] as T;

      final matchingOptionIndex = menu.options!.indexWhere(
        (option) => option.value == context!.selected.single,
      );

      if (matchingOptionIndex >= 0) {
        final builder = await toMultiSelect(result);

        menu.options![matchingOptionIndex] = SelectMenuOptionBuilder(
          label: builder.label,
          value: builder.value,
        );
      }

      return result;
    } on TimeoutException catch (e, s) {
      throw InteractionTimeoutException(
        'Timed out waiting for selection',
        _nearestCommandContext,
      )..stackTrace = s;
    } finally {
      if (menu != null && message != null) {
        menu.isDisabled = true;
        await message.edit(MessageCreateUpdateBuilder.fromMessageBuilder(builder));
      }
    }
  }

  @override
  Future<List<T>> getMultiSelection<T>(
    List<T> choices,
    MessageBuilder builder, {
    ResponseLevel? level,
    Duration? timeout,
    bool authorOnly = true,
    FutureOr<SelectMenuOptionBuilder> Function(T)? toMultiSelect,
    Converter<T>? converterOverride,
  }) async {
    if (_delegate != null) {
      return _delegate!.getMultiSelection(
        choices,
        builder,
        authorOnly: authorOnly,
        converterOverride: converterOverride,
        level: level,
        timeout: timeout,
        toMultiSelect: toMultiSelect,
      );
    }

    toMultiSelect ??= converterOverride?.toMultiselectOption;
    toMultiSelect ??= commands.getConverter(RuntimeType<T>())?.toMultiselectOption;

    if (toMultiSelect == null) {
      throw UncaughtCommandsException(
        'No suitable method for converting $T to MultiselectOptionBuilder found',
        _nearestCommandContext,
      );
    }

    Map<String, T> idToValue = {};
    List<SelectMenuOptionBuilder> options = await Future.wait(choices.map(
      (value) async {
        SelectMenuOptionBuilder builder = await toMultiSelect!(value);
        idToValue[builder.value] = value;
        return builder;
      },
    ));

    ComponentId menuId = ComponentId.generate(
      expirationTime: timeout,
      allowedUser: authorOnly ? user.id : null,
    );

    SelectMenuBuilder menu = SelectMenuBuilder(
      type: MessageComponentType.stringSelect,
      customId: menuId.toString(),
      options: options,
      minValues: choices.length,
    );
    ActionRowBuilder row = ActionRowBuilder(components: [menu]);

    (builder.components ??= []).add(row);

    Message message = await respond(builder, level: level);

    try {
      SelectMenuContext<List<String>> context =
          await commands.eventManager.nextSelectMenuEvent(menuId);

      context._parent = this;
      _delegate = context;

      for (final value in context.selected) {
        final matchingOptionIndex = menu.options!.indexWhere((option) => option.value == value);

        if (matchingOptionIndex >= 0) {
          menu.options![matchingOptionIndex] = SelectMenuOptionBuilder(
            label: menu.options![matchingOptionIndex].label,
            value: value,
          );
        }
      }

      return context.selected.map((id) => idToValue[id]!).toList();
    } on TimeoutException catch (e, s) {
      throw InteractionTimeoutException(
        'TImed out waiting for selection',
        _nearestCommandContext,
      )..stackTrace = s;
    } finally {
      menu.isDisabled = true;
      await message.edit(MessageCreateUpdateBuilder.fromMessageBuilder(builder));
    }
  }
}

mixin InteractionRespondMixin
    implements InteractionInteractiveContext, InteractionContextData, InteractiveMixin {
  @override
  MessageResponse<dynamic> get interaction;

  ResponseLevel? _responseLevel;
  bool _hasResponded = false;

  Future<void>? _acknowledgeLock;

  @override
  Future<Message> respond(MessageBuilder builder, {ResponseLevel? level}) async {
    await _acknowledgeLock;

    if (_delegate != null) {
      return _delegate!.respond(builder, level: level);
    }

    level ??= _nearestCommandContext.command.resolvedOptions.defaultResponseLevel!;

    if (_hasResponded) {
      // We've already responded, just send a followup.
      return interaction.createFollowup(builder, isEphemeral: level.hideInteraction);
    }

    _hasResponded = true;

    if (_responseLevel != null && _responseLevel!.hideInteraction != level.hideInteraction) {
      // We acknowledged the interaction but our original acknowledgement doesn't correspond to
      // what's being requested here.
      // It's a bit ugly, but send an empty response and delete it to match [level].

      await interaction.respond(MessageBuilder(content: '‎'));
      await interaction.deleteOriginalResponse();

      return interaction.createFollowup(builder, isEphemeral: level.hideInteraction);
    }

    // If we want to preserve the original message a component is attached to, we can just send a
    // followup instead of a response.
    // Also, if we are requested to hide interactions, also send a followup, or
    // components will just edit the original message (making it public).
    if (level.hideInteraction) {
      await interaction.respond(builder, isEphemeral: level.hideInteraction);
      return interaction.fetchOriginalResponse();
    }

    if (interaction is MessageComponentInteraction) {
      // Using interactionEvent.respond is actually the same as editing a message in the case where
      // the interaction is a message component. In those cases, leaving `componentRows` as `null`
      // would leave the existing components on the message - which likely isn't what our users
      // expect. Instead, we override them and set the builder to have no components.
      builder.components ??= [];

      await (interaction as MessageComponentInteraction)
          .respond(builder, updateMessage: !level.preserveComponentMessages);
      return interaction.fetchOriginalResponse();
    }

    await interaction.respond(builder, isEphemeral: level.hideInteraction);
    return interaction.fetchOriginalResponse();
  }

  @override
  Future<void> acknowledge({ResponseLevel? level}) async {
    await _acknowledgeLock;

    final lockCompleter = Completer<void>();
    _acknowledgeLock = lockCompleter.future;

    try {
      _responseLevel =
          level ??= _nearestCommandContext.command.resolvedOptions.defaultResponseLevel!;
      if (interaction is MessageComponentInteraction) {
        await (interaction as MessageComponentInteraction).acknowledge(
          isEphemeral: level.hideInteraction,
          updateMessage: !level.preserveComponentMessages,
        );
      } else {
        await interaction.acknowledge(isEphemeral: level.hideInteraction);
      }
    } finally {
      lockCompleter.complete();
      _acknowledgeLock = null;
    }
  }

  @override
  Future<ModalContext> awaitModal(String customId, {Duration? timeout}) async {
    if (_delegate != null) {
      if (_delegate is! InteractionInteractiveContext) {
        throw UncaughtCommandsException(
          "Couldn't delegate awaitModal() to non-interaction context",
          _nearestCommandContext,
        );
      }

      return (_delegate as InteractionInteractiveContext).awaitModal(customId, timeout: timeout);
    }

    Future<ModalSubmitInteraction> event = client.onModalSubmitInteraction
        .map((e) => e.interaction)
        .where(
          (event) => event.data.customId == customId,
        )
        .first;

    if (timeout != null) {
      event = event.timeout(timeout);
    }

    ModalContext context = await commands.contextManager.createModalContext(await event);

    context._parent = this;
    _delegate = context;

    return context;
  }

  @override
  Future<ModalContext> getModal({
    required String title,
    required List<TextInputBuilder> components,
    Duration? timeout,
  }) async {
    if (_delegate != null) {
      if (_delegate is! InteractionInteractiveContext) {
        throw UncaughtCommandsException(
          "Couldn't delegate getModal() to non-interaction context",
          _nearestCommandContext,
        );
      }

      return (_delegate as InteractionInteractiveContext).getModal(
        title: title,
        components: components,
        timeout: timeout,
      );
    }

    final interaction = this.interaction;
    if (interaction is! ModalResponse) {
      throw UncaughtCommandsException(
        'Cannot respond to a context of type $runtimeType with a modal',
        _nearestCommandContext,
      );
    }

    ModalBuilder builder = ModalBuilder(
      customId: ComponentId.generate().toString(),
      title: title,
      components: components.map((textInput) => ActionRowBuilder(components: [textInput])).toList(),
    );

    await (interaction as ModalResponse).respondModal(builder);

    return awaitModal(builder.customId, timeout: timeout);
  }
}

mixin MessageRespondMixin implements InteractiveMixin {
  Message get message;

  @override
  Future<Message> respond(MessageBuilder builder, {ResponseLevel? level}) async {
    if (_delegate != null) {
      return _delegate!.respond(builder, level: level);
    }

    level ??= _nearestCommandContext.command.resolvedOptions.defaultResponseLevel!;

    if (level.isDm) {
      final dmChannel = await client.users.createDm(user.id);
      return dmChannel.sendMessage(builder);
    }

    if (builder.replyId == null) {
      builder.replyId = message.id;

      if (level.mention == true) {
        builder.allowedMentions =
            (builder.allowedMentions ?? AllowedMentions()) | AllowedMentions(repliedUser: true);
      } else if (level.mention == false) {
        builder.allowedMentions =
            (builder.allowedMentions ?? AllowedMentions()) & AllowedMentions(repliedUser: false);
      }
    }

    return channel.sendMessage(builder);
  }
}
