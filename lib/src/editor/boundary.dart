import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart';

/// What shape an object's boundary is.
enum BoundaryKind {
  /// The shape itself. Correct for anything, however odd — a doorway is a
  /// hole you can walk through rather than a wall you cannot.
  mesh('Mesh', 'Follows the shape, holes and all.'),

  /// The smallest upright box the shape fits in. Cheaper to test against, and
  /// what somebody wants for a crate, a lift or a trigger volume — anything
  /// where the box *is* the intent rather than an approximation of it.
  box('Box', 'The smallest box it fits in.'),

  /// None at all: the object is drawn and nothing else. For decoration
  /// somebody should walk straight through.
  none('None', 'Nothing to hit, and nothing to click.');

  const BoundaryKind(this.label, this.hint);

  final String label;
  final String hint;
}

/// Where an object begins and ends, as far as anything but the eye is
/// concerned.
///
/// Separate from the geometry because the two answer different questions.
/// What somebody sees can be a railing of forty thin bars; what they walk
/// into is one slab. Keeping them apart is what lets a shape be detailed and
/// still be cheap to collide with, and what lets a boundary sit a little
/// outside the thing it belongs to — which is nearly always wanted, because
/// something standing exactly on a surface is intersecting it half the time.
class Boundary {
  Boundary({
    this.kind = BoundaryKind.mesh,
    this.padding = 0.0,
    Vector3? offset,
  }) : offset = offset ?? Vector3.zero();

  final BoundaryKind kind;

  /// How far outside the shape it sits, in metres. Negative pulls it inside,
  /// which is how somebody makes a boundary that ignores a decorative shell.
  final double padding;

  /// Where it sits relative to the object, for the times the shape is not
  /// centred on what it is meant to be — a lamp modelled on its bulb whose
  /// boundary belongs round its base.
  final Vector3 offset;

  bool get isNothing => kind == BoundaryKind.none;

  Boundary copyWith({
    BoundaryKind? kind,
    double? padding,
    Vector3? offset,
  }) =>
      Boundary(
        kind: kind ?? this.kind,
        padding: padding ?? this.padding,
        offset: offset ?? this.offset,
      );

  /// The box this boundary occupies, given the shape it belongs to.
  ///
  /// [natural] is what the object occupies with no boundary settings at all.
  /// Used for the broad phase whichever kind this is: a mesh boundary still
  /// wants a box round it, because most rays miss.
  ({Vector3 min, Vector3 max}) boxFrom(({Vector3 min, Vector3 max}) natural) {
    final grow = Vector3.all(padding);
    return (
      min: natural.min + offset - grow,
      max: natural.max + offset + grow,
    );
  }

  /// The geometry a ray is tested against, or null when the boundary is a box
  /// or there is nothing to build one from.
  ///
  /// Rebuilt rather than cached here: this is a description, and whoever holds
  /// it is in a better position to know when the shape changed.
  Mesh? meshFrom(Mesh? shape) {
    if (kind != BoundaryKind.mesh || shape == null || shape.isEmpty) {
      return null;
    }
    final grown = padding == 0 ? shape.copy() : shape.grown(padding);
    if (offset.length2 > 0) {
      for (final at in grown.positions) {
        at.add(offset);
      }
    }
    return grown;
  }

  Map<String, Object?> toJson() => {
        if (kind != BoundaryKind.mesh) 'kind': kind.name,
        if (padding != 0) 'pad': padding,
        if (offset.length2 > 0) 'at': [offset.x, offset.y, offset.z],
      };

  static Boundary? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();

    Vector3? at;
    final raw = map['at'];
    if (raw is List && raw.length >= 3 && raw.every((one) => one is num)) {
      at = Vector3(
        (raw[0]! as num).toDouble(),
        (raw[1]! as num).toDouble(),
        (raw[2]! as num).toDouble(),
      );
    }

    return Boundary(
      kind: BoundaryKind.values.firstWhere(
        (one) => one.name == map['kind'],
        orElse: () => BoundaryKind.mesh,
      ),
      padding: map['pad'] is num ? (map['pad']! as num).toDouble() : 0,
      offset: at,
    );
  }
}
