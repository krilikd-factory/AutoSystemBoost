# Makefile — build asb governor binary
# Usage: make
# Debug: make DEBUG=1

CC      = clang
SRCDIR  = ../src
BINDIR  = ../bin
TARGET  = $(BINDIR)/asb

CFLAGS  = -O2 -fstack-protector-strong -fPIE -pie -I$(SRCDIR)
CFLAGS += -D_FORTIFY_SOURCE=2
CFLAGS += -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare
LDFLAGS = -lm

ifdef DEBUG
CFLAGS  = -g -O0 -fPIE -pie -I$(SRCDIR) -DASB_DEBUG_BUILD=1
CFLAGS += -Wall -Wextra -Wno-unused-parameter
endif

.PHONY: all clean install

all: $(BINDIR) $(TARGET)

$(BINDIR):
	mkdir -p $(BINDIR)

$(TARGET): $(SRCDIR)/asb_governor.c \
           $(SRCDIR)/asb_metrics.h \
           $(SRCDIR)/asb_fsm.h \
           $(SRCDIR)/asb_learner.h \
           $(SRCDIR)/asb_writer.h \
           $(SRCDIR)/asb_socket.h
	$(CC) $(CFLAGS) $< $(LDFLAGS) -o $@
	@command -v strip >/dev/null 2>&1 && strip $@ || true
	@sz=$$(wc -c < $@ 2>/dev/null); echo "Built: $@ ($$sz bytes)"

install: $(TARGET)
	@MODDIR="/data/adb/modules/AutoSystemBoost";\
	mkdir -p "$$MODDIR/bin";\
	cp $(TARGET) "$$MODDIR/bin/asb";\
	chmod 755 "$$MODDIR/bin/asb";\
	echo "Installed to $$MODDIR/bin/asb"

clean:
	rm -f $(TARGET)
