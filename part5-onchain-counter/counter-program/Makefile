# counter — SPEL program: a single u64 that anyone can increment.
#
# Quick start:
#   make build idl deploy
#   make cli ARGS="initialize"
#   make cli ARGS="increment"
#   make inspect-counter         # decode the PDA into JSON

SHELL := /bin/bash
STATE_FILE := .counter-state
IDL_FILE := counter-idl.json
PROGRAMS_DIR := methods/guest/target/riscv32im-risc0-zkvm-elf/docker
PROGRAM_BIN := $(PROGRAMS_DIR)/counter.bin

-include $(STATE_FILE)

define save_var
	@grep -v '^$(1)=' $(STATE_FILE) 2>/dev/null > $(STATE_FILE).tmp || true
	@echo '$(1)=$(2)' >> $(STATE_FILE).tmp
	@mv $(STATE_FILE).tmp $(STATE_FILE)
endef

.PHONY: help build idl cli deploy setup inspect inspect-counter status clean

help:
	@echo "counter — SPEL program"
	@echo ""
	@echo "  make build           Build the zkVM guest binary (needs risc0 toolchain + docker)"
	@echo "  make idl             Generate IDL from program source"
	@echo "  make setup           Create a signer account (run once)"
	@echo "  make deploy          Deploy the program to the sequencer"
	@echo "  make cli ARGS=...    Run the IDL-driven CLI"
	@echo ""
	@echo "Typical flow:"
	@echo "  make build idl setup deploy"
	@echo "  make cli ARGS=\"initialize\""
	@echo "  make cli ARGS=\"increment\""
	@echo "  make inspect-counter"

build:
	cargo risczero build --manifest-path methods/guest/Cargo.toml
	@echo ""
	@echo "OK  guest binary built: $(PROGRAM_BIN)"
	@ls -la $(PROGRAM_BIN) 2>/dev/null || true

idl:
	spel generate-idl methods/guest/src/bin/counter.rs > $(IDL_FILE)
	@echo "OK  IDL -> $(IDL_FILE)"

cli:
	cargo run --bin counter_cli -- $(ARGS)

deploy:
	@test -f "$(PROGRAM_BIN)" || (echo "ERROR: no binary, run 'make build' first"; exit 1)
	wallet deploy-program $(PROGRAM_BIN)
	@echo "OK  program deployed"

inspect:
	cargo run --bin counter_cli -- inspect $(PROGRAM_BIN)

# Decode the on-chain counter PDA into JSON. Seed is `"counter"` — matches
# the `pda = literal("counter")` in methods/guest/src/bin/counter.rs.
inspect-counter:
	@PDA=$$(spel pda counter 2>&1 | tail -1); \
	echo "counter PDA = $$PDA"; \
	spel inspect "$$PDA" --type CounterState

setup:
	@echo "Creating signer account..."
	$(eval SIGNER_ID := $(shell wallet account new public 2>&1 | sed -n 's/.*Public\/\([A-Za-z0-9]*\).*/\1/p'))
	@echo "Signer: $(SIGNER_ID)"
	$(call save_var,SIGNER_ID,$(SIGNER_ID))
	@echo "OK  signer saved to $(STATE_FILE)"

status:
	@echo "counter — status"
	@echo "--------------------------------------"
	@if [ -f "$(STATE_FILE)" ]; then cat $(STATE_FILE); else echo "(no state — run 'make setup')"; fi
	@echo ""
	@echo "Artifacts:"
	@ls -la $(PROGRAM_BIN) 2>/dev/null || echo "  counter.bin:     NOT BUILT (run 'make build')"
	@ls -la $(IDL_FILE) 2>/dev/null || echo "  $(IDL_FILE): NOT GENERATED (run 'make idl')"

clean:
	rm -f $(STATE_FILE) $(STATE_FILE).tmp
	@echo "OK  state cleaned"
