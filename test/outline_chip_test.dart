import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/snapping.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/editor/workspace.dart';
import 'package:orbis_mesh/orbis_mesh.dart';

/// How the viewport shows the selection: the renderer's outline, or the old
/// boundary painted over the picture, and the chip between them.
void main() {
  late Workspace workspace;
  late SceneObject object;

  setUp(() {
    object = SceneObject(
      id: 'a',
      name: 'A',
      kind: ObjectKind.shape,
      shape: Shape.of(ShapeKind.cube),
    );
    workspace = Workspace('/project')
      ..add(SceneEntry(id: 's', name: 'S', scene: EditorScene([object])));
  });

  Future<void> pump(
    WidgetTester tester, {
    Set<String>? selected,
    bool outline = true,
    VoidCallback? onToggle,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: SceneViewport(
              workspace: workspace,
              camera: OrbitCamera(),
              onCameraChanged: (_) {},
              snapping: Snapping(step: 0.5),
              primary: object.id,
              selected: selected ?? {object.id},
              outlineSelection: outline,
              onToggleOutline: onToggle,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The painter that draws boundaries over the picture. Private to the
  /// viewport, so it is found by name rather than by type.
  Finder boundaryPainter() => find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString() == '_SelectionPainter',
  );

  testWidgets('with the outline on, nothing is painted over the picture', (
    tester,
  ) async {
    await pump(tester);
    expect(boundaryPainter(), findsNothing);
    expect(find.text('Outline'), findsOneWidget);
  });

  testWidgets('with it off, the boundary is drawn as it used to be', (
    tester,
  ) async {
    await pump(tester, outline: false);
    expect(boundaryPainter(), findsOneWidget);
    expect(find.text('Boundary'), findsOneWidget);
  });

  testWidgets('the chip switches between them', (tester) async {
    var toggled = 0;
    await pump(tester, onToggle: () => toggled++);
    await tester.tap(find.text('Outline'));
    expect(toggled, 1);
  });

  testWidgets('with nothing selected there is no chip to press', (
    tester,
  ) async {
    await pump(tester, selected: {});
    expect(find.text('Outline'), findsNothing);
    expect(find.text('Boundary'), findsNothing);
  });
}
