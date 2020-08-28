// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:ffigen/src/code_generator/typedef.dart';
import 'package:meta/meta.dart';

import 'binding.dart';
import 'binding_string.dart';
import 'type.dart';
import 'utils.dart';
import 'writer.dart';

/// A binding for C Struct.
///
/// For a C structure -
/// ```c
/// struct C {
///   int a;
///   double b;
///   int c;
/// };
/// ```
/// The generated dart code is -
/// ```dart
/// class Struct extends ffi.Struct{
///  @ffi.Int32()
///  int a;
///
///  @ffi.Double()
///  double b;
///
///  @ffi.Uint8()
///  int c;
///
/// }
/// ```
class Struc extends NoLookUpBinding {
  List<StructMember> members;

  Struc({
    String usr,
    String originalName,
    @required String name,
    String dartDoc,
    List<Member> members,
  })  : members = members ?? [],
        super(
          usr: usr,
          originalName: originalName,
          name: name,
          dartDoc: dartDoc,
        );

  List<int> _getArrayDimensionLengths(Type type) {
    final array = <int>[];
    var startType = type;
    while (startType.broadType == BroadType.ConstantArray) {
      array.add(startType.length);
      startType = startType.child;
    }
    return array;
  }

  List<Typedef> _typedefDependencies;
  @override
  List<Typedef> getTypedefDependencies(Writer w) {
    if (_typedefDependencies == null) {
      _typedefDependencies = <Typedef>[];

      // Write typedef's required by members and resolve name conflicts.
      for (final structMember in members) {
        // BitfieldGroup will not have typedef dependencies so we only run this
        // for the members.
        if (structMember is Member) {
          final base = structMember.type.getBaseType();
          if (base.broadType == BroadType.NativeFunction) {
            _typedefDependencies.addAll(base.nativeFunc.getDependencies());
          }
        }
      }
    }
    return _typedefDependencies;
  }

  @override
  BindingString toBindingString(Writer w) {
    members = members ?? [];
    final s = StringBuffer();
    final enclosingClassName = name;
    if (dartDoc != null) {
      s.write(makeDartDoc(dartDoc));
    }

    final helpers = <ArrayHelper>[];

    final expandedArrayItemPrefix = getUniqueItemPrefix('_unique');
    final bitfieldGroupPrefix = getUniqueItemPrefix('_bitfield');

    /// Adding [enclosingClassName] because dart doesn't allow class member
    /// to have the same name as the class.
    final localUniqueNamer = UniqueNamer({enclosingClassName});

    // Write class declaration.
    s.write(
        'class $enclosingClassName extends ${w.ffiLibraryPrefix}.Struct{\n');
    for (final structMember in members) {
      const depth = '  ';
      if (structMember is Member) {
        final m = structMember;
        final memberName = localUniqueNamer.makeUnique(m.name);
        if (structMember.type.broadType == BroadType.ConstantArray) {
          // TODO(5): Remove array helpers when inline array support arives.
          final arrayHelper = ArrayHelper(
            helperClassGroupName:
                '${w.arrayHelperClassPrefix}_${enclosingClassName}_${memberName}',
            elementType: m.type.getBaseArrayType(),
            dimensions: _getArrayDimensionLengths(m.type),
            name: memberName,
            structName: enclosingClassName,
            elementNamePrefix: '${expandedArrayItemPrefix}${memberName}_item_',
          );
          s.write(arrayHelper.declarationString(w));
          helpers.add(arrayHelper);
        } else {
          if (m.dartDoc != null) {
            s.write(depth + '/// ');
            s.writeAll(m.dartDoc.split('\n'), '\n' + depth + '/// ');
            s.write('\n');
          }
          if (m.type.isPrimitive) {
            s.write('$depth@${m.type.getCType(w)}()\n');
          }
          s.write('$depth${m.type.getDartType(w)} ${memberName};\n\n');
        }
      } else if (structMember is BitfieldGroup) {
        final bitfields = BitfieldHelper(
          bitfieldGroup: structMember,
          bitfieldPrefix: bitfieldGroupPrefix,
        ).generate(w, depth);
        s.write(bitfields + '\n');
      }
    }

    s.write('}\n\n');

    for (final helper in helpers) {
      s.write(helper.helperClassString(w));
    }

    return BindingString(type: BindingStringType.struc, string: s.toString());
  }

  /// Gets a unique prefix in struct's local namespace.
  String getUniqueItemPrefix(String base) {
    var itemPrefix = base;
    var suffixInt = 0;
    var unique = false;
    // Inner function to update prefix.
    void tryNewPrefix() {
      unique = false;
      suffixInt++;
      itemPrefix = '${base}${suffixInt}';
    }

    while (!unique) {
      // Check if prefix is unique, this will be set to false when a match is found.
      unique = true;
      // Check and update if prefix matches with generated dart class name.
      if (name.startsWith(itemPrefix)) {
        tryNewPrefix();
        continue;
      }
      for (final m in members) {
        if (m is Member) {
          if (m.name.startsWith(itemPrefix)) {
            tryNewPrefix();
          }
        } else if (m is BitfieldGroup) {
          for (final bf in m.bitfields) {
            if (bf.name.startsWith(itemPrefix)) {
              tryNewPrefix();
              break;
            }
          }
        }
        // Stop checking member names if prefix is not unique.
        if (!unique) {
          break;
        }
      }
    }

    return itemPrefix + '_';
  }
}

class BitfieldHelper {
  static int _bitfieldGroupsCounter = 0;

  final BitfieldGroup bitfieldGroup;
  final String prefix;

  String rawItemName(int index) => '${prefix}i${index}';

  BitfieldHelper({
    @required this.bitfieldGroup,
    @required String bitfieldPrefix,
  }) : prefix = '${bitfieldPrefix}g${BitfieldHelper._bitfieldGroupsCounter++}_';

  String generate(final Writer w, final String depth) {
    final s = StringBuffer();

    // Write Uint8's to cover the entire bitfield group's padding + size.
    final start = bitfieldGroup.startOffset;
    final end = bitfieldGroup.bitfields.last.bitOffset +
        bitfieldGroup.bitfields.last.length;
    final uint8 = Type.nativeType(SupportedNativeType.Uint8);

    var counter = 0;
    for (var i = start; i < end; i += 8, counter++) {
      s.write('$depth@${uint8.getCType(w)}()\n');
      s.write('$depth${uint8.getDartType(w)} ${rawItemName(counter)};\n');
    }
    // TODO(incomplete): handle bitfield group members;
    return s.toString();
  }
}

// Helper bindings for struct array.
class ArrayHelper {
  final Type elementType;
  final List<int> dimensions;
  final String structName;

  final String name;
  final String helperClassGroupName;
  final String elementNamePrefix;

  int _expandedArrayLength;
  int get expandedArrayLength {
    if (_expandedArrayLength != null) return _expandedArrayLength;

    var arrayLength = 1;
    for (final i in dimensions) {
      arrayLength = arrayLength * i;
    }
    return arrayLength;
  }

  ArrayHelper({
    @required this.elementType,
    @required this.dimensions,
    @required this.structName,
    @required this.name,
    @required this.helperClassGroupName,
    @required this.elementNamePrefix,
  });

  /// Create declaration binding, added inside the struct binding.
  String declarationString(Writer w) {
    final s = StringBuffer();
    final arrayDartType = elementType.getDartType(w);
    final arrayCType = elementType.getCType(w);

    for (var i = 0; i < expandedArrayLength; i++) {
      if (elementType.isPrimitive) {
        s.write('  @${arrayCType}()\n');
      }
      s.write('  ${arrayDartType} ${elementNamePrefix}$i;\n');
    }

    s.write('/// Helper for array `$name`.\n');
    s.write(
        '${helperClassGroupName}_level0 get $name => ${helperClassGroupName}_level0(this, $dimensions, 0, 0);\n');

    return s.toString();
  }

  String helperClassString(Writer w) {
    final s = StringBuffer();
    final arrayType = elementType.getDartType(w);
    for (var dim = 0; dim < dimensions.length; dim++) {
      final helperClassName = '${helperClassGroupName}_level${dim}';
      final structIdentifier = '_struct';
      final dimensionsIdentifier = 'dimensions';
      final levelIdentifier = 'level';
      final absoluteIndexIdentifier = '_absoluteIndex';
      final checkBoundsFunctionIdentifier = '_checkBounds';
      final legthIdentifier = 'length';

      s.write('/// Helper for array `$name` in struct `$structName`.\n');

      // Write class declaration.
      s.write('class ${helperClassName}{\n');
      s.write('final $structName $structIdentifier;\n');
      s.write('final List<int> $dimensionsIdentifier;\n');
      s.write('final int $levelIdentifier;\n');
      s.write('final int $absoluteIndexIdentifier;\n');
      s.write(
          'int get $legthIdentifier => $dimensionsIdentifier[$levelIdentifier];\n');

      // Write class constructor.
      s.write(
          '$helperClassName(this.$structIdentifier, this.$dimensionsIdentifier, this.$levelIdentifier, this.$absoluteIndexIdentifier);\n');

      // Write checkBoundsFunction.
      s.write('''
  void $checkBoundsFunctionIdentifier(int index) {
    if (index >= $legthIdentifier || index < 0) {
      throw RangeError('Dimension \$$levelIdentifier: index not in range 0..\${$legthIdentifier} exclusive.');
    }
  }
  ''');
      // If this isn't the last level.
      if (dim + 1 != dimensions.length) {
        // Override [] operator.
        s.write('''
  ${helperClassGroupName}_level${dim + 1} operator [](int index) {
    $checkBoundsFunctionIdentifier(index);
    var offset = index;
    for (var i = level + 1; i < $dimensionsIdentifier.length; i++) {
      offset *= $dimensionsIdentifier[i];
    }
    return ${helperClassGroupName}_level${dim + 1}(
        $structIdentifier, $dimensionsIdentifier, $levelIdentifier + 1, $absoluteIndexIdentifier + offset);
  }
''');
      } else {
        // This is the last level, add switching logic here.
        // Override [] operator.
        s.write('$arrayType operator[](int index){\n');
        s.write('$checkBoundsFunctionIdentifier(index);\n');
        s.write('switch($absoluteIndexIdentifier+index){\n');
        for (var i = 0; i < expandedArrayLength; i++) {
          s.write('case $i:\n');
          s.write('  return $structIdentifier.${elementNamePrefix}$i;\n');
        }
        s.write('default:\n');
        s.write("  throw Exception('Invalid Array Helper generated.');");
        s.write('}\n');
        s.write('}\n');

        // Override []= operator.
        s.write('void operator[]=(int index, $arrayType value){\n');
        s.write('$checkBoundsFunctionIdentifier(index);\n');
        s.write('switch($absoluteIndexIdentifier+index){\n');
        for (var i = 0; i < expandedArrayLength; i++) {
          s.write('case $i:\n');
          s.write('  $structIdentifier.${elementNamePrefix}$i = value;\n');
          s.write('  break;\n');
        }
        s.write('default:\n');
        s.write("  throw Exception('Invalid Array Helper generated.');\n");
        s.write('}\n');
        s.write('}\n');
      }
      s.write('}\n');
    }
    return s.toString();
  }
}

abstract class StructMember {}

class Member extends StructMember {
  final String dartDoc;
  final String originalName;
  final String name;
  final Type type;
  Member({
    String originalName,
    @required this.name,
    @required this.type,
    this.dartDoc,
  }) : originalName = originalName ?? name;
}

class BitfieldGroup extends StructMember {
  final int startOffset;
  final List<Bitfield> bitfields;
  BitfieldGroup(this.startOffset, this.bitfields);

  @override
  String toString() {
    return 'startOffset: $startOffset, bitfields: $bitfields';
  }
}

class Bitfield {
  final String originalName;
  final String name;
  final SupportedNativeType nativeType;

  /// Length of the bitfield.
  final int length;

  /// Field offset starting from the beginning of the structure.
  final int bitOffset;

  Bitfield({
    String originalName,
    @required this.name,
    @required this.length,
    @required this.bitOffset,
    @required this.nativeType,
  }) : originalName = originalName ?? name;

  @override
  String toString() {
    return '($name($originalName), type: $nativeType, length: $length, bit offset: $bitOffset)';
  }
}
