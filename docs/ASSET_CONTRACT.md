# Požadované demonstrační assety (připraví autor)

Všechny zdrojové .adm/.adm_anim modely se mají verzovat v https://github.com/BerretW/ADM, nikoli nezávisle kopírovat a upravovat v každém enginu. Odkazujte na konkrétní commit nebo release a uveďte SHA-256 souborů.

- `stairs_straight.adm`: stupně, samostatně identifikovatelné bezpečnostní/emisní pásky, kolizní geometrie podle ADM.
- `stairs_spiral.adm`: točité schodiště s nerovnoměrnou orientací stupňů, kontaktní plochy, emisní pásky.
- `character.adm`: humanoidní kostra, dvě validní TWO_BONE IK chains pro nohy a případně ruce, attachment marker pro zbraň, vhodná UV/texturová data.
- `locomotion.adm_anim`: jedna základní animace chůze po rovině; volitelně idle, reload a referenční animace shaderových parametrů.
- `weapon_base.adm`: základ zbraně s definovanými attachment markers a místem pro zásobník.
- `weapon_magazine.adm`, `weapon_optic.adm`, `weapon_barrel.adm`, `weapon_stock.adm`: výměnné komponenty s odpovídajícími markery.
- Volitelné `material_emission.adm_anim`: skutečné animované emisní parametry podle aktuální specifikace; pokud profil animaci neumožňuje, zaznamenat mezeru a nepředstírat podporu.

Nejde o povinné názvy normativního ADM standardu, pouze o doporučené názvy demonstračních souborů. Assety musí projít referenční validací před zapojením do testerů.
