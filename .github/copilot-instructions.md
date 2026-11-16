# Pokyny pro GitHub Copilot Fusion

- Před implementací vždy přečti aktuální https://github.com/BerretW/ADM a normativní https://github.com/BerretW/ADM/blob/main/adm-standard/ADM-1.0-SPEC.md (zejména §§ 3–5, 18–21 a pravidla shaderů/rozšíření). Zaznamenej commit SHA použité specifikace do testovacího reportu.
- ADM je engine-agnostický datový standard. NEMĚŇ specifikaci kvůli Godotu nebo Unrealu; navrhni issue v ADM, pokud najdeš rozpor.
- Implementuj jen funkce doložené aktuální specifikací. Nepřidávej do ADM herní logiku, runtime API nebo proprietární skripty.
- Tester musí podporovat výběr libovolného .adm a příslušných .adm_anim; zobrazit deklarované schopnosti a jasně odlišit supported, unsupported a invalid.
- Žádné tiché zahazování dat. Nepodporovaná rozšíření diagnostikuj; respektuj required/optional pravidla.
- Godot a Unreal musí používat stejné testovací ADM assety a stejné deterministické vstupy. Exportuj strojově čitelný JSON report (asset hash, spec SHA, schopnosti, výsledky, odchylky).
- IK: respektuj ADM-IK-1 TWO_BONE v model-space, numerické a singularitní podmínky, poleOverride, weight, CLAMPED/SOLVED a UNSUPPORTED_ORIENTATION. Nativní solver lze nabídnout jen jako volitelné srovnání, nikoli automaticky prohlásit za shodný.
- Materiály: odliš emisní výstup shaderu od bloom/glow a skutečného osvětlení okolí. Blikání/animaci parametrů testuj prostřednictvím skutečných ADM animačních stop, pouze pokud jsou dané cíle dle aktuální specifikace podporované.
- Pracuj inkrementálně, s testy a reprodukovatelnými instrukcemi ke spuštění. Po každém milníku přidej důkaz (screenshot/video nebo JSON report) a seznam omezení.
