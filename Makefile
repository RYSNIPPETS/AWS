.PHONY: check

check:
	./Tests/smoke.sh
	./Tests/regression.sh
