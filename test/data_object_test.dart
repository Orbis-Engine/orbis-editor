import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/data_object.dart';
import 'package:orbis_editor/src/editor/data_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('orbis_data'));
  tearDown(() => root.deleteSync(recursive: true));

  DataObject full() => DataObject(
        name: 'Ball settings',
        note: 'How the ball behaves',
        fields: [
          DataField(key: 'speed', type: DataType.number, value: 12.5,
              note: 'Metres a second'),
          DataField(key: 'label', type: DataType.text, value: 'Ball'),
          DataField(key: 'bouncy', type: DataType.toggle, value: true),
          DataField(key: 'tint', type: DataType.colour, value: '#D9634F'),
          DataField(key: 'spawn', type: DataType.vector, value: [0, 1, 2]),
          DataField(key: 'mesh', type: DataType.asset, value: 'meshes/ball.glb'),
        ],
      );

  group('the file', () {
    test('survives a round trip with every kind of value', () {
      final back = DataObject.read(full().toText())!;

      expect(back.name, 'Ball settings');
      expect(back.note, 'How the ball behaves');
      expect(back['speed']!.asNumber, 12.5);
      expect(back['speed']!.note, 'Metres a second');
      expect(back['label']!.asText, 'Ball');
      expect(back['bouncy']!.asToggle, isTrue);
      expect(back['tint']!.asColour, const Color(0xFFD9634F));
      expect(back['spawn']!.asVector.z, 2);
      expect(back['mesh']!.asText, 'meshes/ball.glb');
    });

    test('is not read from something that is not one', () {
      expect(DataObject.read('nonsense'), isNull);
      expect(DataObject.read('{"kind":"orbis.prefab"}'), isNull);
    });

    test('a value of the wrong shape falls back rather than failing', () {
      final text = full().toText().replaceAll('12.5', '"fast"');
      final back = DataObject.read(text)!;

      // The field is still there and still a number; only its value reset.
      expect(back['speed']!.type, DataType.number);
      expect(back['speed']!.asNumber, 0);
      expect(back.fields, hasLength(6));
    });

    test('a field with no type is left out, not guessed at', () {
      final back = DataObject.read('''
{"kind":"orbis.data","fields":[
  {"key":"a","type":"number","value":1},
  {"key":"b","value":2}
]}''')!;

      expect([for (final f in back.fields) f.key], ['a']);
    });

    test('a new one is not empty', () {
      expect(DataObject.blank('settings').fields, isNotEmpty);
    });

    test('a second field of a name gets a name of its own', () {
      final data = DataObject.blank('settings');
      expect(data.available('value'), isNot('value'));
    });
  });

  group('the TypeScript it writes', () {
    test('names a type after the object, in Pascal case', () {
      final types = full().toTypeScript('ball');
      expect(types, contains('export interface BallSettings {'));
    });

    test('gives every field the type it actually holds', () {
      final types = full().toTypeScript('ball');

      expect(types, contains('speed: number;'));
      expect(types, contains('label: string;'));
      expect(types, contains('bouncy: boolean;'));
      expect(types, contains('spawn: [number, number, number];'));
      // A colour and an asset are both paths through a string.
      expect(types, contains('tint: string;'));
      expect(types, contains('mesh: string;'));
    });

    test('carries the notes across, since that is where they help', () {
      expect(full().toTypeScript('ball'), contains('/** Metres a second */'));
    });

    test('a name that starts with a digit still makes a legal type', () {
      final data = DataObject(name: '3rd faction', fields: []);
      expect(data.toTypeScript('f'), contains('interface Data3rdFaction'));
    });

    test('says it was generated, so nobody edits it', () {
      expect(full().toTypeScript('ball'), contains('Do not edit'));
    });
  });

  group('the store', () {
    test('reads one from the project', () {
      File(p.join(root.path, 'ball.odata')).writeAsStringSync(full().toText());

      expect(DataStore(root.path)['ball.odata']!.name, 'Ball settings');
    });

    test('a missing file is null rather than a crash', () {
      expect(DataStore(root.path)['nowhere.odata'], isNull);
    });

    test('reads once and holds on to it', () {
      final file = File(p.join(root.path, 'ball.odata'))
        ..writeAsStringSync(full().toText());
      final store = DataStore(root.path);

      expect(store['ball.odata']!.name, 'Ball settings');
      file.writeAsStringSync(
        DataObject(name: 'Changed', fields: []).toText(),
      );

      // Still the first read: forty objects asking on every frame must not be
      // forty file reads.
      expect(store['ball.odata']!.name, 'Ball settings');
      store.forget('ball.odata');
      expect(store['ball.odata']!.name, 'Changed');
    });

    test('writing tells whatever is showing the value', () {
      final store = DataStore(root.path);
      var told = 0;
      store.addListener(() => told++);

      expect(store.write('ball.odata', full()), isNull);
      expect(told, 1);
      expect(File(p.join(root.path, 'ball.odata')).existsSync(), isTrue);
      // And the written one is what comes back, without going to disk again.
      expect(store['ball.odata']!.name, 'Ball settings');
    });

    test('writing into a folder that is not there makes it', () {
      expect(DataStore(root.path).write('data/deep/ball.odata', full()), isNull);
      expect(
        File(p.join(root.path, 'data', 'deep', 'ball.odata')).existsSync(),
        isTrue,
      );
    });
  });
}
