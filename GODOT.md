# Godot-specific tasks

- Použij aktuální stabilní Godot 4.x; zvolenou verzi zapiš do projektu.
- Implementuj runtime loader a testovací scénu. C# je vhodná výchozí volba, ale kritické dekódování může být v GDExtension, pokud je to zdůvodněné benchmarkem.
- Využij ArrayMesh/MeshInstance3D, Skeleton3D, AnimationPlayer/AnimationTree, ShaderMaterial, CollisionShape3D a vlastní editor/runtime UI podle potřeby.
- IK primárně přes vlastní přesnou implementaci ADM-IK-1, nikoli neověřenou náhradu vestavěným solverem.
- Schody: physics raycasts, stance/swing gating, korekce pánve. Osvětlení: WorldEnvironment + světla; emise: materiál a volitelný glow odděleně.
- Předveď interaktivní demo a reporty podle docs/TASKS.md.
