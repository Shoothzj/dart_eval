import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:dart_eval/src/dbc/dbc_executor.dart';
import 'package:dart_eval/src/dbc/dbc_writer.dart';

class DbcGen {
  final out = <DbcOp>[];

  DbcExecutor generate(Map<String, Map<String, String>> packages) {
    final ctx = DbcGenContext(0);

    final packageMap = <String, Map<String, int>>{};
    final namedLibraryMap = <int, String>{};
    final indexMap = <int, List<String>>{};
    final partMap = <int, List<String>>{};
    final partOfMap = <int, String>{};
    final libraryMap = <String, int>{};
    final importMap = <int, List<ImportDirective>>{};
    final topLevelDeclarationsMap = <int, Map<String, Declaration>>{};

    var fileIndex = 0;

    int? resolveUri(List<String> resolvedUriParts) {
      return packageMap[resolvedUriParts[0]]?[resolvedUriParts[1]];
    }

    List<String> resolvedUriParts(String currentPackage, String currentFile, String uri) {
      String package = currentPackage, file, targetFile;
      if (uri.startsWith('package:')) {
        final content = uri.substring(8);
        package = content.substring(0, content.indexOf('/'));
        file = content.substring(content.indexOf('/') + 1);
        targetFile = file;
      } else {
        file = uri;
        if (!currentFile.contains('/')) {
          targetFile = file;
        } else {
          final currentFileNest = currentFile.split('/');
          targetFile = [...currentFileNest.take(currentFileNest.length - 1), ...file.split('/')].join('/');
        }
      }
      return [package, targetFile];
    }

    packages.forEach((package, libraries) {
      packageMap[package] = {};

      libraries.forEach((filename, source) {
        final unit = _parse(source);

        final imports = <ImportDirective>[];
        var myIndex = libraryMap["'package:$package/$filename'"];

        for (final directive in unit.directives) {
          if (directive is PartDirective) {
            final uri = directive.uri.stringValue;
            if (uri == null) {
              throw CompileError('Part URIs cannot use string interpolation');
            }
            if (!uri.startsWith('package:') && uri.contains(':')) {
              throw CompileError('Invalid URI in part directive: starts with ${uri.split(':')[0]}:');
            }
            final uriParts = resolvedUriParts(package, filename, uri);
            final file = resolveUri(uriParts);
            if (file != null) {
              if (partOfMap[file] != "'$filename'") {
                throw CompileError('$package/$filename contains a part directive for $uri, '
                    'but there is no corresponding part of directive');
              }
              myIndex = file;
            } else {
              final idx = myIndex ?? (myIndex = fileIndex++);
              final formattedUri = 'package:${uriParts[0]}/${uriParts[1]}';
              if (!partMap.containsKey(idx)) {
                partMap[idx] = [formattedUri];
              } else {
                partMap[idx]!.add(formattedUri);
              }
            }
            libraryMap["'package:$package/$filename'"] = myIndex;
            indexMap[myIndex] = [package, filename];
          } else if (directive is PartOfDirective) {
            if (unit.directives.length > 1) {
              throw CompileError('"part of" when included must be the only directive in a part');
            }
            final uri = directive.uri?.stringValue;
            final library = directive.libraryName;
            if (uri == null && library == null) {
              throw CompileError('Part URIs cannot use string interpolation');
            }
            if (uri != null) {
              if (!uri.startsWith('package:') && uri.contains(':')) {
                throw CompileError('Invalid URI in part of directive: starts with ${uri.split(':')[0]}:');
              }
              final uriParts = resolvedUriParts(package, filename, uri);
              final file = resolveUri(uriParts);
              final formattedUri = 'package:${uriParts[0]}/${uriParts[1]}';
              final myFormattedUri = 'package:$package/$filename';
              if (file != null) {
                if (partMap[file] == null || !partMap[file]!.contains(myFormattedUri)) {
                  throw CompileError('$package/$filename contains a part of directive for $uri, '
                      'but there is no corresponding part directive');
                }
                partMap[file]!.remove(myFormattedUri);
                myIndex = file;
              } else {
                myIndex = libraryMap["'$formattedUri'"] ?? fileIndex++;
                libraryMap["'$formattedUri'"] = myIndex;
              }
              partOfMap[myIndex] = formattedUri;
            } else {
              throw CompileError('No support for named libraries yet');
            }
          } else if (directive is ImportDirective) {
            imports.add(directive);
          } else {
            throw CompileError('Unknown directive type ${directive.runtimeType}');
          }
        }

        myIndex ??= fileIndex++;
        packageMap[package]![filename] = myIndex;
        indexMap[myIndex] ??= [package, filename];
        importMap[myIndex] = imports;

        ctx.visibleTypes[myIndex] ??= {..._coreDeclarations};
        ctx.visibleDeclarations[myIndex] ??= {};
        topLevelDeclarationsMap[myIndex] ??= {};

        unit.declarations.forEach((d) {
          if (d is NamedCompilationUnitMember) {
            if (topLevelDeclarationsMap[myIndex]!.containsKey(d.name.name)) {
              throw CompileError('Cannot define "${d.name.name} twice in the same library"');
            }
            topLevelDeclarationsMap[myIndex]![d.name.name] = d;
            if (d is ClassDeclaration) {
              ctx.visibleTypes[myIndex]![d.name.name] = TypeRef(myIndex!, d.name.name);
            }
          } else {
            throw CompileError('Not a NamedCompilationUnitMember');
          }
        });

        ctx.visibleDeclarations[myIndex]!.addAll(topLevelDeclarationsMap[myIndex]!
            .map((key, value) => MapEntry(key, DeclarationOrPrefix(myIndex!, declaration: value))));
      });
    });

    importMap.forEach((file, imports) {
      final myUri = indexMap[file]!;
      for (final imp in imports) {
        final uri = imp.uri.stringValue;
        if (uri == null) {
          throw CompileError('Import URI is not a string');
        }
        final resolvedLibrary = resolveUri(resolvedUriParts(myUri[0], myUri[1], uri))!;
        ctx.visibleTypes[file] ??= {};
        ctx.visibleDeclarations[file] ??= {};
        var prefix = imp.prefix?.name ?? '';
        if (prefix != '') {
          prefix = '$prefix.';
        }
        ctx.visibleTypes[resolvedLibrary]!.forEach((key, value) {
          ctx.visibleTypes[file]!['$prefix$key'] = value;
        });
        if (prefix == '') {
          ctx.visibleDeclarations[file]!.addAll(topLevelDeclarationsMap[resolvedLibrary]!
              .map((key, value) => MapEntry(key, DeclarationOrPrefix(resolvedLibrary, declaration: value))));
        } else {
          ctx.visibleDeclarations[file]![prefix] =
              DeclarationOrPrefix(resolvedLibrary, children: topLevelDeclarationsMap[resolvedLibrary]);
        }
      }
    });

    ctx.topLevelDeclarationsMap = topLevelDeclarationsMap;

    topLevelDeclarationsMap.forEach((key, value) {
      ctx.topLevelDeclarationPositions[key] = {};
      print('Generating package:${indexMap[key]!.join("/")}...');
      value.forEach((lib, declaration) {
        ctx.library = key;
        _parseDeclaration(declaration, ctx);
        ctx.scopeFrameOffset = 0;
        ctx.allocNest = [0];
      });
    });

    ctx.deferredOffsets.forEach((pos, offset) {
      final op = out[pos];
      if (op is Call) {
        final resolvedOffset = ctx.topLevelDeclarationPositions[offset.file!]![offset.name!]!;
        final newOp = Call.make(resolvedOffset);
        out[pos] = newOp;
      }
    });

    final ob = DbcWriter().write(ctx.topLevelDeclarationPositions, out);

    return DbcExecutor(ob.buffer.asByteData());
  }

  CompilationUnit _parse(String source) {
    final d = parseString(content: source, throwIfDiagnostics: false);
    if (d.errors.isNotEmpty) {
      for (final error in d.errors) {
        stderr.addError(error);
      }
      throw CompileError('Parsing error(s)');
    }
    return d.unit;
  }

  int pushOp(DbcGenContext ctx, DbcOp op, int length) {
    out.add(op);
    ctx.position += length;
    return out.length - 1;
  }

  int enterScope(DbcGenContext ctx, AstNode scopeHost, int offset, String name) {
    final position = out.length;
    var op = PushScope.make(ctx.library, offset, name);
    pushOp(ctx, op, PushScope.len(op));
    ctx.locals.add({});
    return position;
  }

  void exitScope(DbcGenContext ctx) {
    pushOp(ctx, PopScope.make(), PopScope.LEN);
    ctx.locals.removeLast();
  }

  int? _parseDeclaration(Declaration d, DbcGenContext ctx) {
    if (d is ClassDeclaration) {
      for (final m in d.members) {
        _parseDeclaration(m, ctx)!;
      }
    } else if (d is MethodDeclaration) {
      ctx.functionName = d.name.name;
      final b = d.body;
      int? pos;

      if (b is BlockFunctionBody) {
        pos = _parseBlock(b.block, _returnTypeFromAnnotation(ctx, ctx.library, d.returnType), ctx,
                name: d.name.name + '()')
            .position;
      } else {
        throw CompileError('Unknown function body type ${b.runtimeType}');
      }

      if (d.isStatic) {
        ctx.topLevelDeclarationPositions[ctx.library]![d.name.name] = pos;
      }
      return pos;
    } else if (d is FunctionDeclaration) {
      ctx.functionName = d.name.name;
      ctx.topLevelDeclarationPositions[ctx.library]![d.name.name] = enterScope(ctx, d, d.offset, d.name.name + '()');
      final b = d.functionExpression.body;
      StatementInfo? stInfo;
      if (b is BlockFunctionBody) {
        stInfo = _parseBlock(b.block, _returnTypeFromAnnotation(ctx, ctx.library, d.returnType), ctx,
            name: d.name.name + '()');
      }
      if (stInfo == null || !(stInfo.willAlwaysReturn || stInfo.willAlwaysThrow)) {
        pushOp(ctx, Return.make(-1), Return.LEN);
      }
      ctx.locals.removeLast();
    }
  }

  StatementInfo _parseStatement(Statement s, AlwaysReturnType? expectedReturnType, DbcGenContext ctx) {
    if (s is Block) {
      return _parseBlock(s, expectedReturnType, ctx);
    } else if (s is VariableDeclarationStatement) {
      _parseVariableDeclarationList(s.variables, ctx);
      return StatementInfo(-1);
    } else if (s is ExpressionStatement) {
      _parseExpression(s.expression, ctx);
      return StatementInfo(-1);
    } else if (s is ReturnStatement) {
      _parseReturn(s, expectedReturnType, ctx);
      return StatementInfo(-1, willAlwaysReturn: true);
    }
    return StatementInfo(-1);
  }

  void _buildClassInstantiator(DbcGenContext ctx, ClassDeclaration cls) {
    if (cls.isAbstract) {
      throw CompileError('Cannot create instantiator for abstract class');
    }

    //final j = pushOp(ctx, , length)
  }

  StatementInfo _parseBlock(Block b, AlwaysReturnType? expectedReturnType, DbcGenContext ctx,
      {String name = '<block>'}) {
    final position = out.length;
    ctx.allocNest.add(0);

    var willAlwaysReturn = false;
    var willAlwaysThrow = false;

    for (final s in b.statements) {
      final stInfo = _parseStatement(s, expectedReturnType, ctx);

      if (stInfo.willAlwaysThrow) {
        willAlwaysThrow = true;
        break;
      }
      if (stInfo.willAlwaysReturn) {
        willAlwaysReturn = true;
        break;
      }
    }

    if (!willAlwaysThrow && !willAlwaysReturn) {
      final nestCount = ctx.allocNest.removeLast();

      for (var i = 0; i < nestCount; i++) {
        pushOp(ctx, Pop.make(), Pop.LEN);
      }
    }

    return StatementInfo(position, willAlwaysReturn: willAlwaysReturn, willAlwaysThrow: willAlwaysThrow);
  }

  void _parseReturn(ReturnStatement s, AlwaysReturnType? expectedReturnType, DbcGenContext ctx) {
    if (s.expression == null) {
      pushOp(ctx, Return.make(-1), Return.LEN);
    } else {
      final expected = expectedReturnType?.type ?? _dynamicType;
      var value = _parseExpression(s.expression!, ctx);
      if (!value.type.isAssignableTo(expected)) {
        throw CompileError('Cannot return ${value.type} (expected: $expected)');
      }
      if (_unboxedAcrossFunctionBoundaries.contains(expected)) {
        if (value.boxed) {
          value = _unbox(ctx, value);
        }
      } else if (!value.boxed) {
        value = _box(ctx, value);
      }
      pushOp(ctx, Return.make(value.scopeFrameOffset), Return.LEN);
    }
  }

  Variable _parseExpression(Expression e, DbcGenContext ctx) {
    if (e is Literal) {
      final literalValue = _parseLiteral(e, ctx);
      return _pushBuiltinValue(literalValue, ctx);
    } else if (e is AssignmentExpression) {
      final L = _parseExpression(e.leftHandSide, ctx);
      final R = _parseExpression(e.rightHandSide, ctx);

      if (!R.type.isAssignableTo(L.type)) {
        throw CompileError('Syntax error: cannot assign value of type ${R.type} to ${L.type}');
      }

      pushOp(ctx, CopyValue.make(L.scopeFrameOffset, R.scopeFrameOffset), CopyValue.LEN);
      return L;
    } else if (e is Identifier) {
      return _parseIdentifier(e, ctx);
    } else if (e is MethodInvocation) {
      return _parseMethodInvocation(ctx, e);
    } else if (e is BinaryExpression) {
      return _parseBinaryExpression(ctx, e);
    }

    throw CompileError('Unknown expression type ${e.runtimeType}');
  }

  Variable _parseBinaryExpression(DbcGenContext ctx, BinaryExpression e) {
    var L = _parseExpression(e.leftOperand, ctx);
    var R = _parseExpression(e.rightOperand, ctx);

    final supportedIntIntrinsicOps = {TokenType.PLUS};

    if (L.type == _intType && supportedIntIntrinsicOps.contains(e.operator.type)) {
      if (L.boxed) {
        L = _unbox(ctx, L);
      }
      if (R.boxed) {
        R = _unbox(ctx, R);
      }
      if (e.operator.type == TokenType.PLUS) {
        // Integer intrinsic add
        pushOp(ctx, AddInts.make(L.scopeFrameOffset, R.scopeFrameOffset), AddInts.LEN);
        ctx.allocNest.last++;
        return Variable(ctx.scopeFrameOffset++, _intType, null, boxed: false);
      }
      throw CompileError('Internal error: Invalid intrinsic int op ${e.operator.type}');
    }

    if (!L.boxed) {
      L = _box(ctx, L);
    }

    if (!R.boxed) {
      R = _box(ctx, R);
    }

    final opMap = {TokenType.PLUS: '+', TokenType.MINUS: '-', TokenType.SLASH: '/', TokenType.STAR: '*'};

    var method = opMap[e.operator.type] ?? (throw CompileError('Unknown binary operator ${e.operator.type}'));

    final addendOp = PushArg.make(R.scopeFrameOffset);
    pushOp(ctx, addendOp, PushArg.LEN);

    final op = InvokeDynamic.make(L.scopeFrameOffset, method);
    pushOp(ctx, op, InvokeDynamic.len(op));

    pushOp(ctx, PushReturnValue.make(), PushReturnValue.LEN);
    ctx.allocNest.last++;

    final returnType = _queryMethodReturnType(ctx, L.type, method, [R.type], {});

    return Variable(ctx.scopeFrameOffset++, returnType?.type ?? _dynamicType, returnType?.nullable ?? true, boxed: true)
      ..frameIndex = ctx.locals.length - 1;
  }

  Variable _unbox(DbcGenContext ctx, Variable V) {
    assert(V.boxed);
    pushOp(ctx, Unbox.make(V.scopeFrameOffset), Unbox.LEN);
    ctx.allocNest.last++;
    return ctx.locals[V.frameIndex!][V.name!] = Variable(ctx.scopeFrameOffset++, V.type, V.nullable, boxed: false)
      ..name = V.name
      ..frameIndex = V.frameIndex;
  }

  Variable _box(DbcGenContext ctx, Variable V) {
    assert(!V.boxed);
    if (V.type != _intType) {
      throw CompileError('Can only box ints for now');
    }
    pushOp(ctx, BoxInt.make(V.scopeFrameOffset), BoxInt.LEN);
    ctx.allocNest.last++;
    final V2 = Variable(ctx.scopeFrameOffset++, _intType, V.nullable, boxed: true)
      ..name = V.name
      ..frameIndex = V.frameIndex;
    if (V.name != null) {
      ctx.locals[V.frameIndex!][V.name!] = V2;
    }
    return V2;
  }

  Variable _parseMethodInvocation(DbcGenContext ctx, MethodInvocation e) {
    Variable? L;
    if (e.target != null) {
      L = _parseExpression(e.target!, ctx);
    }

    final _args = <Variable>[];
    final _namedArgs = <String, Variable>{};
    var hasEncounteredNamedArg = false;

    for (final arg in e.argumentList.arguments) {
      if (arg is NamedExpression) {
        _namedArgs[arg.name.label.name] = _parseExpression(arg.expression, ctx);
        hasEncounteredNamedArg = true;
      } else {
        if (hasEncounteredNamedArg) {
          throw CompileError('Positional arguments cannot occur after named arguments');
        }
        _args.add(_parseExpression(arg, ctx));
      }
    }

    for (final arg in _args) {
      final argOp = PushArg.make(arg.scopeFrameOffset);
      pushOp(ctx, argOp, PushArg.LEN);
    }

    for (final arg in _namedArgs.entries) {
      final argOp = PushNamedArg.make(arg.value.scopeFrameOffset, arg.key);
      pushOp(ctx, argOp, PushNamedArg.len(argOp));
    }

    AlwaysReturnType? mReturnType;
    final _argTypes = _args.map((e) => e.type).toList();
    final _namedArgTypes = _namedArgs.map((key, value) => MapEntry(key, value.type));

    if (L != null) {
      final op = InvokeDynamic.make(L.scopeFrameOffset, e.methodName.name);
      pushOp(ctx, op, InvokeDynamic.len(op));

      mReturnType = _queryMethodReturnType(ctx, L.type, e.methodName.name, _argTypes, _namedArgTypes);
    } else {
      final method = _parseIdentifier(e.methodName, ctx);
      if (method.methodOffset == null) {
        throw CompileError('Cannot call ${e.methodName.name} as it is not a valid method');
      }
      final offset = method.methodOffset!;
      final loc = pushOp(ctx, Call.make(offset.offset ?? -1), Call.LEN);
      if (offset.offset == null) {
        ctx.deferredOffsets[loc] = offset;
      }
      mReturnType = _returnTypeToAlwaysReturnType(
          method.methodReturnType ?? AlwaysReturnType(_dynamicType, true), _argTypes, _namedArgTypes);
    }

    pushOp(ctx, PushReturnValue.make(), PushReturnValue.LEN);
    ctx.allocNest.last++;

    return Variable(ctx.scopeFrameOffset++, mReturnType?.type ?? _dynamicType, mReturnType?.nullable ?? true,
        boxed: L == null && !_unboxedAcrossFunctionBoundaries.contains(mReturnType?.type));
  }

  void _parseVariableDeclarationList(VariableDeclarationList l, DbcGenContext ctx) {
    TypeRef? type;
    if (l.type != null) {
      type = getTypeRefFromAnnotation(ctx, ctx.library, l.type!);
    }
    final nullable = l.type?.question != null;

    for (final li in l.variables) {
      final init = li.initializer;
      if (init != null) {
        final res = _parseExpression(init, ctx);
        if (ctx.locals.last.containsKey(li.name.name)) {
          throw CompileError('Cannot declare variable ${li.name.name} multiple times in the same scope');
        }
        ctx.locals.last[li.name.name] = Variable(res.scopeFrameOffset, type ?? res.type, nullable, boxed: res.boxed)
          ..name = li.name.name
          ..frameIndex = ctx.locals.length - 1;
      }
    }
  }

  TypeRef getTypeRefFromAnnotation(DbcGenContext ctx, int library, TypeAnnotation typeAnnotation) {
    if (!(typeAnnotation is NamedType)) {
      throw CompileError('No support for generic function types yet');
    }
    return ctx.visibleTypes[library]![typeAnnotation.name.name]!;
  }

  TypeRef getTypeRef(DbcGenContext ctx, String name) {
    return ctx.visibleTypes[ctx.library]![name]!;
  }

  AlwaysReturnType _returnTypeFromAnnotation(DbcGenContext ctx, int library, TypeAnnotation? typeAnnotation) {
    final AlwaysReturnType returnType;
    final rt = typeAnnotation;
    if (rt != null) {
      return AlwaysReturnType(getTypeRefFromAnnotation(ctx, ctx.library, rt), rt.question != null);
    } else {
      return AlwaysReturnType(_dynamicType, true);
    }
  }

  AlwaysReturnType? _queryMethodReturnType(
      DbcGenContext ctx, TypeRef type, String method, List<TypeRef?> argTypes, Map<String, TypeRef?> namedArgTypes) {
    if (_knownMethods[type] != null && _knownMethods[type]!.containsKey(method)) {
      final knownMethod = _knownMethods[type]![method]!;
      final returnType = knownMethod.returnType;
      if (returnType == null) {
        return null;
      }
      return _returnTypeToAlwaysReturnType(returnType, argTypes, namedArgTypes);
    }

    throw UnimplementedError();
  }

  AlwaysReturnType? _returnTypeToAlwaysReturnType(
      ReturnType returnType, List<TypeRef?> argTypes, Map<String, TypeRef?> namedArgTypes) {
    if (returnType is ParameterTypeDependentReturnType) {
      final paramIndex = returnType.paramIndex;
      final paramName = returnType.paramName;

      AlwaysReturnType? resolvedType;
      if (paramIndex != null) {
        resolvedType = returnType.map[argTypes[paramIndex]];
      } else if (paramName != null) {
        resolvedType = returnType.map[namedArgTypes[paramName]];
      }

      if (resolvedType == null) {
        return returnType.fallback;
      }
      return resolvedType;
    }
    return returnType as AlwaysReturnType;
  }

  Variable _pushBuiltinValue(BuiltinValue value, DbcGenContext ctx) {
    if (value.type == BuiltinValueType.intType) {
      pushOp(ctx, PushConstantInt.make(value.intval!), PushConstantInt.LEN);
      ctx.allocNest.last++;
      return Variable(ctx.scopeFrameOffset++, _intType, null, boxed: false);
    } else if (value.type == BuiltinValueType.stringType) {
      final op = PushConstantString.make(value.stringval!);
      pushOp(ctx, op, PushConstantString.len(op));
      ctx.allocNest.last++;
      return Variable(ctx.scopeFrameOffset++, _stringType, null, boxed: false);
    } else {
      throw CompileError('Cannot push unknown builtin value type ${value.type}');
    }
  }

  BuiltinValue _parseLiteral(Literal l, DbcGenContext ctx) {
    if (l is IntegerLiteral) {
      return BuiltinValue(intval: l.value);
    } else if (l is SimpleStringLiteral) {
      return BuiltinValue(stringval: l.stringValue);
    }
    throw CompileError('Unknown literal type ${l.runtimeType}');
  }

  Variable _parseIdentifier(Identifier id, DbcGenContext ctx) {
    if (id is SimpleIdentifier) {
      for (var i = ctx.locals.length - 1; i >= 0; i--) {
        if (ctx.locals[i].containsKey(id.name)) {
          return ctx.locals[i][id.name]!..frameIndex = i;
        }
      }

      //print(ctx.visibleDeclarations);
      final declaration = ctx.visibleDeclarations[ctx.library]![id.name]!;
      final decl = declaration.declaration!;

      if (!(decl is FunctionDeclaration)) {
        throw CompileError('No support for class identifiers');
      }

      TypeRef? returnType;
      var nullable = true;
      if (decl.returnType != null) {
        returnType = getTypeRefFromAnnotation(ctx, declaration.sourceLib, decl.returnType!);
        nullable = decl.returnType!.question != null;
      }

      final DeferredOrOffset offset;
      if (ctx.topLevelDeclarationPositions[declaration.sourceLib]?.containsKey(id.name) ?? false) {
        offset = DeferredOrOffset(
            file: declaration.sourceLib, offset: ctx.topLevelDeclarationPositions[ctx.library]![id.name]);
      } else {
        offset = DeferredOrOffset(file: declaration.sourceLib, name: id.name);
      }

      return Variable(-1, _functionType, null,
          methodOffset: offset, methodReturnType: AlwaysReturnType(returnType, nullable));
    }
    throw CompileError('Unknown identifier ${id.runtimeType}');
  }
}

class DbcGenContext {
  DbcGenContext(this.sourceFile);

  int library = 0;
  int position = 0;
  int scopeFrameOffset = 0;
  String functionName = '';
  List<List<AstNode>> scopeNodes = [];
  List<Map<String, Variable>> locals = [];
  Map<int, Map<String, Declaration>> topLevelDeclarationsMap = {};
  Map<int, DeferredOrOffset> deferredOffsets = {};
  Map<int, Map<String, TypeRef>> visibleTypes = {};
  Map<int, Map<String, DeclarationOrPrefix>> visibleDeclarations = {};
  Map<int, Map<String, int>> topLevelDeclarationPositions = {};
  List<int> allocNest = [0];
  int sourceFile;
}

class DeclarationOrPrefix {
  DeclarationOrPrefix(this.sourceLib, {this.declaration, this.children});

  int sourceLib;
  Declaration? declaration;
  Map<String, Declaration>? children;
}

class Variable {
  Variable(this.scopeFrameOffset, this.type, this.nullable,
      {this.methodOffset, this.methodReturnType, this.boxed = true});

  final int scopeFrameOffset;
  final TypeRef type;
  final DeferredOrOffset? methodOffset;
  final ReturnType? methodReturnType;
  final bool boxed;

  bool? nullable;
  String? name;
  int? frameIndex;
}

class StatementInfo {
  StatementInfo(this.position, {this.willAlwaysReturn = false, this.willAlwaysThrow = false});

  final int position;
  final bool willAlwaysReturn;
  final bool willAlwaysThrow;
}

class DeferredOrOffset {
  DeferredOrOffset({this.offset, this.file, this.name});

  final int? offset;
  final int? file;
  final String? name;

  @override
  String toString() {
    return 'DeferredOrOffset{offset: $offset, file: $file, name: $name}';
  }
}

class BuiltinValue {
  BuiltinValue({this.intval, this.doubleval, this.stringval}) {
    if (intval != null) {
      type = BuiltinValueType.intType;
    } else if (stringval != null) {
      type = BuiltinValueType.stringType;
    } else if (doubleval != null) {
      type = BuiltinValueType.doubleType;
    }
  }

  late BuiltinValueType type;
  final int? intval;
  final double? doubleval;
  final String? stringval;

  int get length {
    switch (type) {
      case BuiltinValueType.intType:
      case BuiltinValueType.doubleType:
        return 4;
      case BuiltinValueType.stringType:
        return 1 + stringval!.length;
    }
  }
}

enum BuiltinValueType { intType, stringType, doubleType }

class TypeRef {
  const TypeRef(this.file, this.name,
      {this.extendsType,
      this.implementsType = const [],
      this.withType = const [],
      this.genericParams = const [],
      this.specifiedTypeArgs = const []});

  final int file;
  final String name;
  final TypeRef? extendsType;
  final List<TypeRef> implementsType;
  final List<TypeRef> withType;
  final List<GenericParam> genericParams;
  final List<TypeRef> specifiedTypeArgs;

  List<TypeRef> get allSupertypes => [if (extendsType != null) extendsType!, ...implementsType, ...withType];

  bool isAssignableTo(TypeRef slot, {List<TypeRef>? overrideGenerics}) {
    final generics = overrideGenerics ?? specifiedTypeArgs;

    if (this == slot) {
      for (var i = 0; i < generics.length; i++) {
        if (slot.specifiedTypeArgs.length >= i - 1) {
          if (!generics[i].isAssignableTo(slot.specifiedTypeArgs[i])) {
            return false;
          }
        }
      }
      return true;
    }

    for (final type in allSupertypes) {
      if (type.isAssignableTo(slot, overrideGenerics: generics)) {
        return true;
      }
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TypeRef && runtimeType == other.runtimeType && file == other.file && name == other.name;

  @override
  int get hashCode => file.hashCode ^ name.hashCode;

  @override
  String toString() {
    return name;
  }
}

class KnownMethod {
  const KnownMethod(this.returnType, this.args, this.namedArgs);

  final ReturnType? returnType;
  final List<KnownMethodArg> args;
  final Map<String, KnownMethodArg> namedArgs;
}

class KnownMethodArg {
  const KnownMethodArg(this.name, this.type, this.optional, this.nullable);

  final String name;
  final TypeRef? type;
  final bool optional;
  final bool nullable;
}

class ReturnType {}

class AlwaysReturnType implements ReturnType {
  const AlwaysReturnType(this.type, this.nullable);

  final TypeRef? type;
  final bool nullable;
}

class ParameterTypeDependentReturnType implements ReturnType {
  const ParameterTypeDependentReturnType(this.map, {this.paramIndex, this.paramName, this.fallback});

  final int? paramIndex;
  final String? paramName;
  final Map<TypeRef, AlwaysReturnType> map;
  final AlwaysReturnType? fallback;
}

class GenericParam {
  const GenericParam(this.name, this.extendsType);

  final String name;
  final TypeRef? extendsType;
}

const int _dartCoreFile = -1;
const TypeRef _dynamicType = TypeRef(_dartCoreFile, 'dynamic');
const TypeRef _objectType = TypeRef(_dartCoreFile, 'Object', extendsType: _dynamicType);
const TypeRef _numType = TypeRef(_dartCoreFile, 'num', extendsType: _objectType);
final TypeRef _intType = TypeRef(_dartCoreFile, 'int', extendsType: _numType);
final TypeRef _doubleType = TypeRef(_dartCoreFile, 'double', extendsType: _numType);
const TypeRef _stringType = TypeRef(_dartCoreFile, 'String', extendsType: _objectType);
const TypeRef _mapType = TypeRef(_dartCoreFile, 'Map', extendsType: _objectType);
const TypeRef _listType = TypeRef(_dartCoreFile, 'List', extendsType: _objectType);
const TypeRef _functionType = TypeRef(_dartCoreFile, 'Function', extendsType: _objectType);

final Map<String, TypeRef> _coreDeclarations = {
  'dynamic': _dynamicType,
  'Object': _objectType,
  'num': _numType,
  'String': _stringType,
  'int': _intType,
  'double': _doubleType,
  'Map': _mapType,
  'List': _listType,
  'Function': _functionType
};

final _intBinaryOp = KnownMethod(
    ParameterTypeDependentReturnType({
      _doubleType: AlwaysReturnType(_doubleType, false),
      _intType: AlwaysReturnType(_intType, false),
      _numType: AlwaysReturnType(_numType, false)
    }, paramIndex: 0, fallback: AlwaysReturnType(_numType, false)),
    [KnownMethodArg('other', _numType, false, false)],
    {});

final _doubleBinaryOp =
    KnownMethod(AlwaysReturnType(_doubleType, false), [KnownMethodArg('other', _numType, false, false)], {});

final _numBinaryOp = KnownMethod(
    ParameterTypeDependentReturnType({
      _doubleType: AlwaysReturnType(_doubleType, false),
    }, paramIndex: 0, fallback: AlwaysReturnType(_numType, false)),
    [KnownMethodArg('other', _numType, false, false)],
    {});

final Map<TypeRef, Map<String, KnownMethod>> _knownMethods = {
  _intType: {
    '+': _intBinaryOp,
    '-': _intBinaryOp,
    '/': _intBinaryOp,
    '%': _intBinaryOp,
  },
  _doubleType: {
    '+': _doubleBinaryOp,
    '-': _doubleBinaryOp,
    '/': _doubleBinaryOp,
    '%': _doubleBinaryOp,
  },
  _numType: {
    '+': _numBinaryOp,
    '-': _numBinaryOp,
    '/': _numBinaryOp,
    '%': _numBinaryOp,
  }
};

final Set<TypeRef> _unboxedAcrossFunctionBoundaries = {_intType, _doubleType};

class CompileError implements Exception {
  final String message;

  CompileError(this.message);

  @override
  String toString() {
    return 'CompileError: $message';
  }
}