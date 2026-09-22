import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// A spring keeps its current velocity when a gesture reverses direction.
class LuminaSpring extends AnimationController {
  LuminaSpring({required super.vsync, super.value}) : super.unbounded();
  void settle(double target, {bool reducedMotion = false}) {
    if (reducedMotion) {
      stop();
      value = target;
      return;
    }
    animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 380, damping: 29),
        value,
        target,
        velocity,
        tolerance: const Tolerance(distance: .0005, velocity: .0005),
      ),
    );
  }
}
