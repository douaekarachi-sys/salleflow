# SalleFlow

Système de gestion des réservations de salles de réunion.
Projet du module DevOps — UIR.

L'architecture repose sur **trois schémas PostgreSQL isolés**, un par API,
conformément aux tickets TA-30, TA-31 et TA-32 :

| Schéma | API | Ticket |
|---|---|---|
| `employee_identity` | Employee Identity API | TA-30 |
| `room_inventory` | Room Inventory API | TA-31 |
| `core_booking` | Core Booking API | TA-32 |

Chaque schéma a son propre rôle PostgreSQL. Seul `core_booking` dispose
d'une lecture sur les deux autres, pour valider qu'un employé et une salle
existent avant de créer une réservation.

---

## Démarrage

Ouvrir le dossier dans VS Code, puis dans le terminal intégré :

```powershell
Copy-Item .env.example .env
notepad .env                     # remplacer les deux mots de passe
docker compose up -d --build
```

Compter environ une minute au premier lancement.

```powershell
docker compose ps
curl http://localhost:8000/health
```

La sonde doit répondre `{"statut":"ok","base":"ok","schemas":3}`.
Si `schemas` vaut moins de 3, une migration a échoué.

### Les quatre interfaces

| Service | Adresse |
|---|---|
| API + Swagger | http://localhost:8000/docs |
| Base de données (Adminer) | http://localhost:8081 |
| Tableaux de bord (Grafana) | http://localhost:3000 |
| Métriques (Prometheus) | http://localhost:9090 |

Deux conteneurs travaillent sans interface : `liquibase`, qui applique le
changelog puis s'arrête en `Exited (0)` — c'est normal —, et
`postgres-exporter`, qui traduit l'état de PostgreSQL pour Prometheus.

---

## Accéder à la base de données

### Adminer — http://localhost:8081

| Champ | Valeur |
|---|---|
| Système | PostgreSQL |
| Serveur | `db` |
| Utilisateur | `salleflow` |
| Mot de passe | celui du `.env` |
| Base de données | `salleflow` |

**Le serveur est `db`, pas `localhost`.** Adminer tourne dans un conteneur
et joint PostgreSQL par son nom de service sur le réseau Docker. Saisir
`localhost` échouera — c'est l'erreur la plus fréquente à cet écran.

Une fois connectée, le sélecteur en haut à gauche permet de basculer entre
les trois schémas.

### Ce qui ne marchera jamais

**Ouvrir http://localhost:5432 dans un navigateur.** PostgreSQL parle un
protocole binaire, pas HTTP. Le navigateur affiche
« localhost didn't send any data ». Ce n'est pas une panne, il n'y a
simplement aucune page web à cette adresse.

### En ligne de commande

```powershell
docker compose exec db psql -U salleflow -d salleflow
```

| Commande | Effet |
|---|---|
| `\dn` | Lister les schémas |
| `\dt employee_identity.*` | Tables d'un schéma |
| `\d+ core_booking.reservation` | Détail d'une table |
| `\q` | Quitter |

### Depuis VS Code

L'extension SQLTools est préconfigurée : icône base de données dans la barre
latérale, connexion « SalleFlow local », mot de passe = celui du `.env`.

---

## Vérifier les règles de gestion

C'est la preuve de recette du projet.

```powershell
Get-Content db/tests/verification.sql | docker compose exec -T db psql -U salleflow -d salleflow
```

PowerShell n'accepte pas l'opérateur `<`, d'où le `Get-Content |`.
Le dossier étant aussi monté dans le conteneur, ceci fonctionne également :

```powershell
docker compose exec db psql -U salleflow -d salleflow -f /tests/verification.sql
```

**Résultat attendu :** les tests 1, 2, 5 et 6 produisent une erreur
PostgreSQL — c'est le comportement correct, la base refuse ce qu'elle doit
refuser. Les tests 0, 3, 4 et les requêtes 7 à 9 réussissent.

Test par API :

```powershell
pip install -r app/requirements-dev.txt
pytest tests/ -v
```

`test_une_seule_reservation_survit` envoie 20 demandes simultanées sur le
même créneau et vérifie qu'une seule aboutit. C'est la démonstration que la
vérification applicative ne suffit pas et que la contrainte `EXCLUDE`
arbitre.

---

## Arborescence

```
salleflow/
├── docker-compose.yml
├── .env.example                 Modèle de configuration (copier en .env)
├── .vscode/                     Tâches et extensions recommandées
├── app/                         API FastAPI
│   ├── Dockerfile
│   ├── main.py                  /health, /metrics, montage des routeurs
│   ├── database.py              Moteur SQLAlchemy
│   ├── models.py                Modèles répartis sur les trois schémas
│   ├── schemas.py               Validation Pydantic
│   └── routers/
│       ├── employes.py          Employee Identity API
│       ├── salles.py            Room Inventory API
│       └── reservations.py      Core Booking API
├── db/
│   ├── changelog/               Changelog Liquibase (master + 7 changesets)
│   └── tests/verification.sql   Preuve des règles de gestion
├── monitoring/
│   ├── prometheus/              Cibles de collecte
│   └── grafana/                 Sources de données + tableau de bord
├── tests/test_concurrence.py    Tests de concurrence
└── docs/GIT.md                  Publication sur GitHub
```

---

## Les migrations

| Fichier | Ticket | Contenu |
|---|---|---|
| `001-init-base-et-extensions.sql` | TA-8 | Extension `btree_gist`, fondations |
| `002-schema-employee-identity.sql` | TA-30 | Schéma + table `employe` |
| `003-schema-room-inventory.sql` | TA-31 | Schéma + type + table `salle` |
| `004-schema-core-booking.sql` | TA-32 | Schéma + table `reservation`, colonne générée |
| `005-contraintes-chevauchement.sql` | — | RG-04, RG-05, vue d'occupation |
| `006-roles-et-cloisonnement.sql` | — | Rôles et droits par schéma |
| `007-donnees-reference.sql` | — | Jeu de données + cas de l'énoncé |

L'ordre est contraint et fixé explicitement dans
`db/changelog/db.changelog-master.xml` : `004` référence les tables de `002`
et `003`, et `005` a besoin de l'extension de `001`.

Chaque changeset porte son instruction de rollback, ce qui permet
d'annuler une migration :

```powershell
docker compose run --rm liquibase status --verbose   # ce qui reste à appliquer
docker compose run --rm liquibase updateSQL          # prévisualiser sans exécuter
docker compose run --rm liquibase rollbackCount 1    # annuler le dernier changeset
```

Un changeset déjà appliqué ne doit **jamais** être modifié : Liquibase en
garde une somme de contrôle dans la table `databasechangelog` et refusera
de continuer. Pour corriger, on ajoute un nouveau fichier.

### Optimisation pour les requêtes temporelles (TA-32)

La colonne `creneau` est **générée** par PostgreSQL à partir de `debut` et
`duree_minutes`, et **matérialisée** (`STORED`). C'est ce qui la rend
indexable — on ne peut pas indexer un calcul refait à chaque lecture.

Les contraintes de `V5` créent deux index GiST sur cette colonne. Ils
servent à la fois à interdire les chevauchements et à répondre aux
requêtes de disponibilité. La requête 9 du script de vérification affiche
le plan d'exécution pour le prouver.

La borne `'[)'` est inclusive à gauche, exclusive à droite : une réunion
10h–12h et une réunion 12h–13h ne se chevauchent pas.

---

## Tâches VS Code

`Ctrl+Shift+P` → `Tasks: Run Task` :

1. Stack : démarrer
2. Base : vérifier les règles de gestion
3. Tests : concurrence

Puis, selon les besoins : ouvrir psql, rejouer les migrations, arrêter la
stack, tout réinitialiser, suivre les logs.

---

## Dépannage

**`liquibase` sort en erreur** — lire d'abord `docker compose logs liquibase`.
Si le message parle de somme de contrôle (`checksum`), un changeset déjà
appliqué a été modifié : Liquibase refuse par sécurité. En développement,
`docker compose down -v` repart de zéro. En production, on ajoute un
nouveau changeset au lieu de modifier l'ancien.

**`/tests/verification.sql: No such file or directory`** — le conteneur
tournait avant l'ajout du montage. Forcer sa recréation :
`docker compose up -d --force-recreate db`. Vérifier avec
`docker compose config | Select-String "tests"`.

**Adminer refuse la connexion** — le serveur est `db`, pas `localhost`.

**Grafana affiche « No data »** — vérifier les cibles sur
http://localhost:9090/targets. `salleflow-app` et `postgres` doivent être `UP`.

**Échec de téléchargement des images (TLS handshake timeout)** — trop de
téléchargements en parallèle. Dans Docker Desktop → Settings →
Docker Engine, ajouter `"max-concurrent-downloads": 1` au JSON existant
(une seule paire d'accolades englobantes), puis Apply & restart.

**Port déjà utilisé** — modifier le mapping dans `docker-compose.yml`,
par exemple `"8001:8000"`.

**Repartir de zéro** — `docker compose down -v` supprime les volumes,
donc les données et tout tableau de bord modifié à la main.

---

## Publication sur GitHub

Voir `docs/GIT.md`. Le point critique : vérifier la sortie de `git status`
avant le premier commit — `.env` ne doit pas y figurer.
