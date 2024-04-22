TARGETS := $(shell cat .targets 2>/dev/null)

BIN_DIR=/usr/local/bin

BIN_FILES=\
	find_m4.sh		\
	package_decompcheck_all.sh	\
	package_scan_all.sh	\
	package_unpack_all.sh	\
	populate_m4_db.sh	\

install:
	@mkdir -p $(BIN_DIR) && \
	 for BIN_FILE in $(BIN_FILES) ; do \
	   if [ -f $${BIN_FILE} ]; then \
	     install -m 755 $${BIN_FILE} $(BIN_DIR) ; \
	   else \
	     install -m 755 bin/$${BIN_FILE} $(BIN_DIR) ; \
	   fi ; \
	 done

diff:
	@for A in $(BIN_FILES) ; do \
	   if [ -f $(BIN_DIR)/$${A} ]; then \
	     if [ -f $${A} ]; then \
	       diff -u $(BIN_DIR)/$${A} $${A} ; \
	     else \
	       diff -u $(BIN_DIR)/$${A} bin/$${A} ; \
	     fi ; \
	   else \
	     echo "File $${A} is new" ; \
	   fi ; \
	 done ; \
	 true

dist:
	@for TARGET in $(TARGETS) ; do \
	  echo DEST: $${TARGET} ; \
	  rsync -aP Makefile bin/* $${TARGET}: ; \
	done
