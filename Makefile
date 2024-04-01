TARGETS := $(shell cat .targets 2>/dev/null)

BIN_DIR=/usr/local/bin

BIN_FILES=\
	package_unpack_all.sh	\
	package_scan_all.sh	\

install:
	@mkdir -p $(BIN_DIR) && \
	 for BIN_FILE in $(BIN_FILES) ; do \
	   install -m 755 $${BIN_FILE} $(BIN_DIR) ; \
	 done

diff:
	@for A in $(BIN_FILES) ; do \
	   if [ -f $(BIN_DIR)/$${A} ]; then \
	     diff -u $(BIN_DIR)/$${A} $${A} ; \
	   else \
	     echo "File $${A} is new" ; \
	   fi ; \
	 done ; \
	 true

dist:
	@for TARGET in $(TARGETS) ; do \
	  rsync -aP Makefile bin/* $${TARGET}: ; \
	done
