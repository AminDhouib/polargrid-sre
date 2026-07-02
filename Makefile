.PHONY: setup up down status health version logs teardown load rollout degrade recover monitor test demo history compare

setup:
	bash deploy.sh setup

up:
	bash deploy.sh up

down:
	bash deploy.sh down

status:
	bash deploy.sh status

health:
	bash deploy.sh health

version:
	bash deploy.sh version

logs:
	bash deploy.sh logs $(LOC)

teardown:
	bash deploy.sh teardown

load:
	bash deploy.sh load $(LOC)

rollout:
	bash deploy.sh rollout $(VER)

degrade:
	bash deploy.sh degrade $(LOC)

recover:
	bash deploy.sh recover $(LOC)

rollback:
	bash deploy.sh rollback $(LOC)

monitor:
	bash monitor.sh

test:
	bash test.sh

demo:
	bash demo.sh

history:
	bash deploy.sh history

compare:
	bash compare.sh $(N)
