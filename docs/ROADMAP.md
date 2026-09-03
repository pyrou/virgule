# Roadmap de Virgule

Cette checklist est la source de vérité du périmètre. Une case n'est cochée qu'après vérification dans un commit qui compile, sauf les tâches de documentation qui ne produisent pas de binaire.

## Règles d'itération

- [ ] Chaque étape se termine par un commit atomique.
- [ ] Chaque commit applicatif compile sur macOS 14 Apple Silicon.
- [ ] Chaque fonctionnalité a une vérification reproductible (test, commande ou procédure documentée).
- [ ] Le CSV source n'est jamais ouvert en écriture.
- [ ] Les traitements lourds ne bloquent jamais le thread principal AppKit.

## 0. Fondation — en cours

- [x] Initialiser le dépôt Git.
- [x] Documenter la vision produit, les contraintes et l'architecture cible.
- [x] Créer cette roadmap détaillée.
- [x] Créer le commit initial de documentation.

## 1. Workspace compilable

- [ ] Créer le projet Xcode AppKit macOS 14+ / arm64.
- [ ] Créer le crate Rust du moteur et un script de build intégré à Xcode.
- [ ] Définir une API FFI C minimale et sûre pour créer/détruire un moteur.
- [ ] Ajouter la cible de tests Rust.
- [ ] Documenter les prérequis et les commandes de build/test.
- [ ] Vérifier un build Debug de l'application.

## 2. Ingestion CSV fiable

- [ ] Détecter virgule, point-virgule, tabulation et pipe.
- [ ] Autoriser le remplacement manuel du séparateur.
- [ ] Lire UTF-8, UTF-16 et Windows-1252; exposer un choix manuel.
- [ ] Gérer header présent ou absent.
- [ ] Parser en streaming, y compris champs quoted avec séparateur.
- [ ] Parser en streaming, y compris champs quoted avec retour à la ligne.
- [ ] Gérer les guillemets échappés.
- [ ] Inférer null, booléen, entier, décimal, date/datetime et texte.
- [ ] Préserver le texte lorsque l'inférence est ambiguë.
- [ ] Écrire les tests unitaires Rust exigés pour virgule quoted et retour à la ligne quoted.

## 3. Cache SQLite et moteur de requêtes

- [ ] Créer un cache SQLite local associé au fichier source.
- [ ] Importer en transaction unique avec statements préparés.
- [ ] Créer la table `csv` et conserver les métadonnées de colonnes.
- [ ] Exposer progression, aperçu précoce, fin et erreurs via FFI.
- [ ] Paginer les résultats sans les matérialiser côté UI.
- [ ] Valider les requêtes lecture seule : `SELECT`, `WITH`, `EXPLAIN`.
- [ ] Rejeter `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ATTACH` et autres écritures.
- [ ] Ajouter tests de validation SQL et pagination.

## 4. Application AppKit et ouverture de fichier

- [ ] Créer une fenêtre macOS native avec barre d'outils.
- [ ] Ajouter le file picker CSV.
- [ ] Ajouter drag-and-drop de fichier CSV.
- [ ] Lancer l'import hors du thread principal.
- [ ] Afficher un aperçu des premières lignes pendant l'import.
- [ ] Afficher clairement « Lecture seule — le fichier source n'est pas modifié ».
- [ ] Afficher progression et erreurs actionnables.

## 5. Grille virtualisée

- [ ] Implémenter une grille AppKit native virtualisée.
- [ ] Garder le header figé.
- [ ] Garder des numéros de ligne stables.
- [ ] Rendre les colonnes redimensionnables.
- [ ] Charger les pages SQLite à la demande lors du scroll.
- [ ] Réutiliser les vues de lignes/cellules visibles.
- [ ] Vérifier qu'aucune cellule n'est créée pour les lignes invisibles.
- [ ] Mesurer le scroll sur un dataset d'un million de lignes.

## 6. Query bar SQL

- [ ] Afficher en permanence le SQL actif au-dessus de la grille.
- [ ] Permettre l'édition multi-ligne et l'exécution avec Command-Return.
- [ ] Répercuter immédiatement un SQL valide dans la grille.
- [ ] Mettre à jour le SQL lisible depuis les actions de tri/filtre.
- [ ] Ajouter coloration syntaxique, indentation et pretty print.
- [ ] Ajouter validation pendant la frappe avec ligne/colonne d'erreur.
- [ ] Ajouter autocomplétion contextuelle (mots-clés, table, colonnes, fonctions).
- [ ] Ajouter aide rapide fonctions/opérateurs, undo/redo, historique et copie.
- [ ] Permettre les colonnes calculées SQL dans la vue.

## 7. Interactions de données

- [ ] Ajouter recherche Command-F (dataset entier ou colonne, texte/regex).
- [ ] Ajouter tri mono/multi-colonne avec Shift-clic.
- [ ] Ajouter filtres texte, vide/non-vide, numérique et date.
- [ ] Ajouter sélection cellule, plage, ligne, colonne et multi-sélection Command.
- [ ] Copier la sélection en TSV avec Command-C.
- [ ] Ajouter annotations locales colorées par ligne.
- [ ] Ajouter sidebar fichier, bookmarks et schéma.
- [ ] Ajouter inspector optionnel (type, nulls, distincts).

## 8. Persistance et qualité MVP

- [ ] Sauvegarder/restaurer bookmarks : nom, SQL, colonnes visibles, tailles, tri/filtres, annotations, état d'affichage.
- [ ] Ajouter export explicite d'une vue vers un nouveau CSV (si retenu).
- [ ] Ajouter un générateur local de dataset d'un million de lignes.
- [ ] Mesurer import, recherche, tri et scrolling avec procédure documentée.
- [ ] Définir les seuils de performance et les exécuter sur Apple Silicon.
- [ ] Vérifier accessibilité, raccourcis macOS et états d'erreur.
- [ ] Vérifier l'absence d'écriture dans le CSV source.
- [ ] Construire et tester la version MVP avant tout polish visuel.
