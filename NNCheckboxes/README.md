# NNCheckboxes – PCF Control pour grille N:N

Composant PCF (Power Component Framework) permettant d'afficher une liste de cases à cocher (ou toggles) pour gérer des relations N:N dans Dynamics 365 / Power Apps.

Source originale : [MscrmTools/PCF-Controls](https://github.com/MscrmTools/PCF-Controls/tree/master/NNCheckboxes)

---

## Configuration appliquée

| Paramètre | Valeur |
|---|---|
| **Table (DataSet)** | Web Roles (`adx_webrole`) |
| **Vue** | Active Web Roles |
| **Label** (`displayAttribute`) | Name (Text) |
| **Group by** (`categoryAttribute`) | Name (Text) |
| **Colonnes** (`columnsNumber`) | 2 |
| **Layout** (`useToggleSwitch`) | Check boxes |
| **Switch Off color** | `#CC0000` |
| **Switch On color** | `#008800` |
| **Show custom errors** | No |
| **Allow to select a category** | Yes |
| **Display Search** | Yes |
| **Background color** | *(non configuré)* |
| **Foreground color** | *(non configuré)* |
| **Filter attribute** | *(non configuré)* |
| **Filter attribute (parent)** | *(non configuré)* |
| **Relationship schema name** | *(laisser vide si une seule relation N:N existe)* |

---

## Prérequis

- [Node.js](https://nodejs.org/) >= 16
- [Power Platform CLI](https://learn.microsoft.com/en-us/power-platform/developer/cli/introduction) (`pac`)
- [.NET SDK](https://dotnet.microsoft.com/) (pour le build MSBuild / `.pcfproj`)

---

## Installation & développement

```bash
cd NNCheckboxes
npm install
npm run start        # serveur de dev local
npm run build        # build production
```

## Déploiement vers Dataverse

```bash
# Générer la solution
msbuild /t:build /restore

# Importer via PAC CLI
pac solution import --path out/controls/NNCheckboxes.zip
```

## Structure des fichiers

```
NNCheckboxes/
├── NNCheckboxes/
│   ├── ControlManifest.Input.xml   # Définition du composant
│   ├── index.ts                     # Logique principale
│   ├── referential.ts               # Opérateurs de condition
│   ├── reldef.ts                    # Classe RelationshipInfo
│   ├── css/
│   │   └── NNCheckboxes.css         # Styles
│   ├── strings/
│   │   ├── NNCheckboxes.1033.resx   # Anglais
│   │   ├── NNCheckboxes.1036.resx   # Français
│   │   └── NNCheckboxes.1031.resx   # Allemand
│   └── imgs/
├── NNCheckboxes.pcfproj             # Projet MSBuild
├── package.json
├── tsconfig.json
└── pcfconfig.json
```
