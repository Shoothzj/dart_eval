import 'package:dart_eval/src/dbc/dbc_exception.dart';
import 'package:dart_eval/src/dbc/dbc_function.dart';

import 'dbc_class.dart';
import 'dbc_executor.dart';

class DbcObject implements DbcInstance {
  DbcObject();

  @override
  dynamic get evalValue => null;

  @override
  dynamic get reifiedValue => evalValue;

  @override
  DbcInstance? get evalSuperclass => null;

  @override
  DbcValue? evalGetProperty(String identifier) {
    throw UnimplementedError();
  }

  @override
  void evalSetProperty(String identifier, DbcValueInterface value) {
    throw UnimplementedError();
  }
}

class DbcNum<T extends num> implements DbcInstance {
  DbcNum(this.evalValue);

  @override
  T evalValue;

  @override
  DbcValueInterface? evalGetProperty(String identifier) {
    switch(identifier) {
      case '+':
        return __plus;
      case '-':
        return __minus;
    }
    return evalSuperclass.evalGetProperty(identifier);
  }

  @override
  void evalSetProperty(String identifier, DbcValueInterface value) {

  }

  @override
  DbcInstance evalSuperclass = DbcObject();

  @override
  num get reifiedValue => evalValue;

  static final DbcFunctionImpl __plus = DbcFunctionImpl(_plus);
  static DbcValueInterface? _plus(DbcVmInterface vm, DbcValueInterface? target,
      List<DbcValueInterface?> positionalArgs, Map<String, DbcValueInterface?> namedArgs) {
    final addend = positionalArgs[0];

    if (target is DbcInt && addend is DbcInt) {
      return DbcInt(target.evalValue + addend.evalValue);
    }

    throw UnimplementedError();
  }

  static final DbcFunctionImpl __minus = DbcFunctionImpl(_minus);
  static DbcValueInterface? _minus(DbcVmInterface vm, DbcValueInterface? target,
      List<DbcValueInterface?> positionalArgs, Map<String, DbcValueInterface?> namedArgs) {
    final addend = positionalArgs[0];

    if (target is DbcInt && addend is DbcInt) {
      return DbcInt(target.evalValue - addend.evalValue);
    }

    throw UnimplementedError();
  }


}

class DbcInt extends DbcNum<int> {

  DbcInt(int evalValue) : super(evalValue);

  @override
  DbcValueInterface? evalGetProperty(String identifier) {
    return super.evalGetProperty(identifier);
  }

  @override
  void evalSetProperty(String identifier, DbcValueInterface value) {
    return super.evalSetProperty(identifier, value);
  }

  @override
  DbcInstance get evalSuperclass => throw UnimplementedError();

  @override
  int get reifiedValue => evalValue;
}

class DbcInvocation implements DbcInstance {

  DbcInvocation.getter(this.positionalArguments);

  final DbcList2? positionalArguments;

  @override
  DbcValueInterface? evalGetProperty(String identifier) {
    switch (identifier) {
      case 'positionalArguments':
        return positionalArguments;
    }
  }

  @override
  void evalSetProperty(String identifier, DbcValueInterface value) {

  }

  @override
  DbcInstance? get evalSuperclass => throw UnimplementedError();

  @override
  dynamic get evalValue => throw UnimplementedError();

  @override
  dynamic get reifiedValue => throw UnimplementedError();

}


class DbcList2 implements DbcInstance {

  DbcList2(this.evalValue);

  @override
  final List<DbcValue> evalValue;

  @override
  DbcInstance evalSuperclass = DbcObject();

  @override
  DbcValueInterface? evalGetProperty(String identifier) {
    switch (identifier) {
      case '[]':

    }
  }

  @override
  void evalSetProperty(String identifier, DbcValueInterface value) {
    throw EvalUnknownPropertyException(identifier);
  }



  @override
  List get reifiedValue => evalValue.map((e) => e.reifiedValue).toList();
}

class DbcList extends DbcInstanceImpl {
  DbcList(DbcExecutor exec, Map<String, int> lookupGetter, Map<String, int> lookupSetter)
      : super(DbcObject()) {
    evalValue = [];
  }
}