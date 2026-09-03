# Virgule

Explorateur CSV local et natif pour macOS — **"TablePlus pour les CSV"**.

Virgule permet d'explorer, filtrer, trier et requêter de très grands fichiers CSV sans jamais modifier le fichier source. Les modifications sont des vues SQL réversibles, stockées localement avec leurs bookmarks et annotations.

> **Statut : fondation du projet.** L'application compilable sera construite par itérations; suivre [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Principes produit

- macOS 14+ et Apple Silicon uniquement;
- application 100 % native : AppKit + Swift pour l'interface, Rust pour le moteur;
- aucun navigateur embarqué, WebView ou JavaScript;
- fichier CSV source strictement en lecture seule;
- aucune édition de cellule, formule ou fonctionnalité de tableur;
- traitement asynchrone : le thread UI ne fait jamais d'import ni de requête coûteuse;
- priorité à la fluidité sur des fichiers d'un million de lignes.

## Architecture cible

```text
AppKit (Swift)
  ├── Sidebar / query bar / inspector
  └── Grille NSView virtualisée
           │ FFI (API C stable)
           ▼
Moteur Rust
  ├── Détection encodage et séparateur
  ├── Parser CSV streaming et inférence de types
  ├── Import SQLite transactionnel (statements préparés)
  ├── Validation SQL lecture seule
  └── Pagination, recherche et métadonnées
           │
           ▼
Cache local temporaire par fichier source (SQLite)
```

Le CSV est lu en flux par Rust et importé dans une base SQLite de cache. La grille ne reçoit que des pages de résultats; elle ne crée donc pas de cellules pour les lignes hors écran. La table importée s'appelle `csv`.

La query bar affiche toujours le SQL exact de la vue. Les actions de tri et filtre produisent du SQL lisible. Seules les requêtes `SELECT`, `WITH` et `EXPLAIN` sont autorisées; toute instruction qui peut modifier SQLite est refusée.

## CSV pris en charge

- séparateurs détectés : virgule, point-virgule, tabulation, pipe — avec remplacement manuel;
- champs quoted, guillemets échappés, séparateurs et retours à la ligne dans les champs;
- UTF-8, UTF-16 et Windows-1252, avec détection et choix manuel;
- headers optionnels;
- inférence prudente : texte, entier, décimal, booléen, date/datetime et null.

En cas d'ambiguïté, le texte brut reste préservé.

## Itérations prévues

1. Documentation et socle de dépôt (cette itération).
2. Workspace Swift/Rust compilable et FFI minimal.
3. Parser streaming, import SQLite et tests de correction.
4. Fenêtre AppKit, ouverture de fichier et aperçu.
5. Grille virtualisée paginée.
6. Query bar SQL et opérations de vue.
7. Recherche, sélection/copie, bookmarks et annotations.
8. Mesures de performance et durcissement MVP.

Le détail et les critères d'acceptation sont dans [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Lancer l'application

L'application n'est pas encore initialisée : cette première itération ne contient volontairement que la documentation et le plan de construction. Les commandes de build et de test seront ajoutées dès que le workspace compilable existera (itération 2).

## Non-objectifs

- réécrire ou sauvegarder automatiquement le CSV source;
- tableur, mise en forme ou formules dans les cellules;
- chargement complet du dataset dans la mémoire de l'interface.

Une exportation explicite d'une vue vers un nouveau CSV pourra être ajoutée ultérieurement.
