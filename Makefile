.PHONY: up down reset logs verif psql test migrate status rollback

up:        ## Demarrer la stack
	docker compose up -d --build

down:      ## Arreter la stack
	docker compose down

reset:     ## Tout reinitialiser, y compris les donnees
	docker compose down -v && docker compose up -d --build

logs:      ## Suivre les logs de l'application
	docker compose logs -f app

verif:     ## Verifier les regles de gestion en base
	docker compose exec db psql -U $${POSTGRES_USER:-salleflow} -d $${POSTGRES_DB:-salleflow} -f /tests/verification.sql

psql:      ## Ouvrir une session psql
	docker compose exec db psql -U $${POSTGRES_USER:-salleflow} -d $${POSTGRES_DB:-salleflow}

migrate:   ## Appliquer les migrations Liquibase
	docker compose run --rm liquibase update

status:    ## Statut des changesets
	docker compose run --rm liquibase status --verbose

rollback:  ## Annuler le dernier changeset
	docker compose run --rm liquibase rollbackCount 1

test:      ## Lancer les tests de concurrence
	pytest tests/ -v
