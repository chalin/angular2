import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:angular_compiler/cli.dart';
import 'package:code_builder/code_builder.dart';
import 'package:meta/meta.dart' hide literal;
import 'package:path/path.dart' as p;
import 'package:source_gen/source_gen.dart';

import '../link.dart';
import '../types.dart';
import 'dependencies.dart';
import 'modules.dart';
import 'providers.dart';
import 'tokens.dart';

/// Determines details for generating code as a result of `@Injector.generate`.
class InjectorReader {
  static const _package = 'package:angular';
  static const _runtime = '$_package/src/di/injector/injector.dart';
  static const _$Injector = Reference('Injector', _runtime);

  static bool _shouldGenerateInjector(TopLevelVariableElement element) {
    return $GenerateInjector.hasAnnotationOfExact(element);
  }

  /// Returns a list of all injectors needing generation in [element].
  static List<InjectorReader> findInjectors(LibraryElement element) {
    final source = element.source.uri;
    if (source == null) {
      throw StateError('Expected a source for $element.');
    }
    return element.definingCompilationUnit.topLevelVariables
        .where(_shouldGenerateInjector)
        .map((field) => InjectorReader(
              field,
              LibraryReader(element),
              doNotScope: source,
            ))
        .toList();
  }

  /// `@GenerateInjector` annotation object;
  final ConstantReader annotation;

  /// A top-level `InjectorFactory` field annotated with `@GenerateInjector`.
  final TopLevelVariableElement field;

  @protected
  final ModuleReader moduleReader;

  @protected
  final LibraryReader libraryReader;

  /// Originating file URL.
  ///
  /// If non-null, references to symbols in this URL are not scoped.
  ///
  /// Workaround for https://github.com/dart-lang/code_builder/issues/148.
  @protected
  final Uri doNotScope;

  List<ProviderElement> _providers;

  InjectorReader(
    this.field,
    this.libraryReader, {
    this.moduleReader = const ModuleReader(),
    this.doNotScope,
  }) : this.annotation = ConstantReader(
          $GenerateInjector.firstAnnotationOfExact(field),
        );

  @alwaysThrows
  void _throwParseError([DartObject context]) {
    BuildError.throwForElement(
      field,
      context == null
          ? 'Unable to parse @GenerateInjector. You may have analysis errors'
          : 'Unable to parse @GenerateInjector. A provider\'s token ($context) '
          'was read as "null". This is either invalid configuration or you '
          'have analysis errors',
    );
  }

  @alwaysThrows
  void _throwFactoryProvider(DartObject context) {
    BuildError.throwForElement(
        field,
        'Invalid provider ($context): an explicit value of `null` was passed in '
        'where a function is expected.');
  }

  /// Providers that are part of the provided list of the annotation.
  Iterable<ProviderElement> get providers {
    if (_providers == null) {
      final providersOrModules = annotation.read('_providersOrModules');
      if (providersOrModules.isNull) {
        _throwParseError();
      }
      try {
        final module = moduleReader.parseModule(providersOrModules.objectValue);
        _providers = moduleReader.deduplicateProviders(module.flatten());
      } on NullTokenException catch (e) {
        _throwParseError(e.constant);
      } on NullFactoryException catch (e) {
        _throwFactoryProvider(e.constant);
      } on BuildError {
        logWarning('An error occurred parsing providers on $doNotScope');
        rethrow;
      }
    }
    return _providers;
  }

  /// Creates a codegen reference to [symbol] in [url].
  ///
  /// Compares against [doNotScope], which is usually the current library. This
  /// is required because while some URLs can be referenced via `package:`,
  /// others cannot (i.e. those in a `test` directory), so we need to compute
  /// the relative path to them.
  Reference _referSafe(String symbol, String url) {
    if (url == null) {
      // The type dynamic has no URL.
      return refer(symbol);
    }
    final toUrl = Uri.parse(url);
    if (doNotScope != null && toUrl.scheme == 'asset') {
      return _referRelative(symbol, toUrl);
    }
    return refer(symbol, toUrl.toString());
  }

  Reference _referRelative(String symbol, Uri url) {
    // URL segments indicating the origin.
    final from = p.split(doNotScope.normalizePath().path)..removeLast();

    // URL segments indicating the target.
    final to = p.split(url.path);

    // This is pointing to a package: location. We can safely just link.
    if (to[1] == 'lib') {
      to.removeAt(1);
      return refer(symbol, 'package:${to.join('/')}');
    }

    // Verify this is the same package:.
    if (to[0] != from[0]) {
      return refer(symbol, url.toString());
    }

    // This is pointing to a true asset: location, needing a relative link.
    final path = p.relative(to.skip(2).join('/'), from: from.skip(2).join('/'));
    return refer(symbol, path);
  }

  Expression _tokenToIdentifier(TokenElement token) {
    if (token is TypeTokenElement) {
      return _referSafe(token.link.symbol, token.link.import);
    }
    final opaqueToken = token as OpaqueTokenElement;
    final preciseToken = linkToReference(opaqueToken.classUrl, libraryReader);
    return preciseToken.constInstance(
      opaqueToken.identifier.isNotEmpty
          ? [literalString(opaqueToken.identifier)]
          : [],
    );
  }

  List<Expression> _computeDependencies(Iterable<DependencyElement> deps) {
    // TODO(matanl): Optimize.
    return deps.map((dep) {
      if (dep.self) {
        if (dep.optional) {
          return refer('injectFromSelfOptional').call([
            _tokenToIdentifier(dep.token),
            literalNull,
          ]);
        } else {
          return refer('injectFromSelf').call([
            _tokenToIdentifier(dep.token),
          ]);
        }
      }
      if (dep.skipSelf) {
        if (dep.optional) {
          return refer('injectFromAncestryOptional').call([
            _tokenToIdentifier(dep.token),
            literalNull,
          ]);
        } else {
          return refer('injectFromAncestry').call([
            _tokenToIdentifier(dep.token),
          ]);
        }
      }
      if (dep.host) {
        if (dep.optional) {
          return refer('injectFromParentOptional').call([
            _tokenToIdentifier(dep.token),
            literalNull,
          ]);
        } else {
          return refer('injectFromParent').call([
            _tokenToIdentifier(dep.token),
          ]);
        }
      }
      if (dep.optional) {
        return refer('injectOptionalUntyped').call([
          _tokenToIdentifier(dep.token),
          literalNull,
        ]);
      } else {
        return refer('inject').call([
          _tokenToIdentifier(dep.token),
        ]);
      }
    }).toList();
  }

  /// Uses [visitor] to emit the results of this reader.
  void accept(InjectorVisitor visitor) {
    visitor.visitMeta('_Injector\$${field.name}', '${field.name}\$Injector');
    var index = 0;
    for (final provider in providers) {
      if (provider is UseValueProviderElement) {
        final actualValue = _reviveAny(provider, provider.useValue);
        visitor.visitProvideValue(
          index,
          provider.token,
          _tokenToIdentifier(provider.token),
          linkToReference(provider.providerType, libraryReader),
          actualValue,
          provider.isMulti,
        );
      } else if (provider is UseClassProviderElement) {
        final name = provider.dependencies.bound.name;
        visitor.visitProvideClass(
          index,
          provider.token,
          _tokenToIdentifier(provider.token),
          _referSafe(provider.useClass.symbol, provider.useClass.import),
          name.isNotEmpty ? name : null,
          _computeDependencies(provider.dependencies.positional),
          provider.isMulti,
        );
      } else if (provider is UseFactoryProviderElement) {
        visitor.visitProvideFactory(
          index,
          provider.token,
          _tokenToIdentifier(provider.token),
          linkToReference(provider.providerType, libraryReader),
          _referSafe(
            provider.useFactory.fragment,
            provider.useFactory.removeFragment().toString(),
          ),
          _computeDependencies(provider.dependencies.positional),
          provider.isMulti,
        );
      } else if (provider is UseExistingProviderElement) {
        visitor.visitProvideExisting(
          index,
          provider.token,
          _tokenToIdentifier(provider.token),
          linkToReference(provider.providerType, libraryReader),
          _tokenToIdentifier(provider.redirect),
          provider.isMulti,
        );
      }
      index++;
    }
    // Implicit provider: provide(Injector).
    visitor.visitProvideValue(
      index,
      null,
      _$Injector,
      _$Injector,
      refer('this'),
      false,
    );
  }

  /// Returns a revivable `const` invocation as a code_builder [Expression].
  Expression _revive(UseValueProviderElement provider, Revivable invocation) {
    if (invocation.isPrivate) {
      final privateReference = invocation.accessor?.isNotEmpty == true
          ? '${invocation.source}::${invocation.accessor}'
          : '${invocation.source}';
      throw BuildError(''
          'While attempting to resolve a constant value for a provider '
          '(token = ${provider.token}), there was no way to access '
          '$privateReference.\n\n'
          'While it is synactically valid to write the expression, we are '
          'not able to refer to private references that are inaccessible from '
          'another library.\n\n'
          'Consider either making constructor(s) public, creating a static '
          '(or top-level) public field that references the private one, or use '
          'a factory provider instead of a value provider to create the '
          'instance.');
    }
    final import = libraryReader.pathToUrl(invocation.source.removeFragment());
    if (invocation.source.fragment.isNotEmpty) {
      // We can create this invocation by calling `const ...`.
      final name = invocation.source.fragment;
      final positionalArgs = invocation.positionalArguments
          .map((a) => _reviveAny(provider, a))
          .toList();
      final namedArgs = invocation.namedArguments
          .map((name, a) => new MapEntry(name, _reviveAny(provider, a)));
      final clazz = refer(name, '$import');
      if (invocation.accessor.isNotEmpty) {
        return clazz.constInstanceNamed(
          invocation.accessor,
          positionalArgs,
          namedArgs,
        );
      }
      return clazz.constInstance(positionalArgs, namedArgs);
    }
    // We can create this invocation by referring to a const field.
    final name = invocation.accessor;
    return refer(name, '$import');
  }

  Expression _reviveAny(UseValueProviderElement provider, DartObject object) {
    final reader = ConstantReader(object);
    if (reader.isNull) {
      return literalNull;
    }
    if (reader.isList) {
      return _reviveList(provider, reader.listValue);
    }
    if (reader.isMap) {
      return _reviveMap(provider, reader.mapValue);
    }
    if (reader.isLiteral) {
      // Always emit strings as raw in order to emit valid code.
      // See https://github.com/dart-lang/angular/issues/1591.
      if (reader.isString) {
        return literalString(reader.literalValue, raw: true);
      }
      return literal(reader.literalValue);
    }
    final revive = reader.revive();
    if (revive != null) {
      return _revive(provider, revive);
    }
    // TODO(matanl): Make the error actionable after source_gen#374.
    // https://github.com/dart-lang/source_gen/issues/374
    throw BuildError('Could not reference const object ($object)');
  }

  Expression _reviveList(
    UseValueProviderElement provider,
    List<DartObject> list,
  ) =>
      literalConstList(list.map((v) => _reviveAny(provider, v)).toList());

  Expression _reviveMap(
    UseValueProviderElement provider,
    Map<DartObject, DartObject> map,
  ) =>
      literalConstMap(map.map((k, v) =>
          MapEntry(_reviveAny(provider, k), _reviveAny(provider, v))));
}

/// To be implemented by an emitter class to create a `GeneratedInjector`.
abstract class InjectorVisitor {
  /// Implement storing meta elements of this injector, such as its [name].
  void visitMeta(String className, String factoryName);

  /// Implement providing a new instance of [type], calling [constructor].
  ///
  /// Any [dependencies] are expected to invoke local methods as appropriate:
  /// ```dart
  /// refer('inject').call([refer('Dep1')])
  /// ```
  void visitProvideClass(
    int index,
    TokenElement token,
    Expression tokenExpression,
    Reference type,
    String constructor,
    List<Expression> dependencies,
    bool isMulti,
  );

  /// Implement redirecting to [redirect] when [token] is requested.
  void visitProvideExisting(
    int index,
    TokenElement token,
    Expression tokenExpression,
    Reference type,
    Expression redirect,
    bool isMulti,
  );

  /// Implement providing [token] by calling [function].
  ///
  /// Any [dependencies] are expected to invoke local methods as appropriate:
  /// ```dart
  /// refer('inject').call([refer('Dep1')])
  /// ```
  void visitProvideFactory(
    int index,
    TokenElement token,
    Expression tokenExpression,
    Reference returnType,
    Reference function,
    List<Expression> dependencies,
    bool isMulti,
  );

  /// Implement providing [value] when [token] is requested.
  void visitProvideValue(
    int index,
    TokenElement token,
    Expression tokenExpression,
    Reference returnType,
    Expression value,
    bool isMulti,
  );
}
