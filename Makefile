CUDDURL = ftp://vlsi.colorado.edu/pub/cudd-2.5.1.tar.gz
CUDDFILE = $(HOME)/src/cudd-2.5.1.tar.gz
CABALFLAGS = --reinstall --force-reinstalls --extra-include-dirs=$(HOME)/src/cudd-2.5.1/cudd --extra-include-dirs=$(HOME)/src/cudd-2.5.1/mtr --extra-include-dirs=$(HOME)/src/cudd-2.5.1/epd --extra-include-dirs=$(HOME)/src/cudd-2.5.1/st --extra-include-dirs=$(HOME)/src/cudd-2.5.1/util --extra-lib-dirs=$(HOME)/src/cudd-2.5.1/cudd --extra-lib-dirs=$(HOME)/src/cudd-2.5.1/mtr --extra-lib-dirs=$(HOME)/src/cudd-2.5.1/epd --extra-lib-dirs=$(HOME)/src/cudd-2.5.1/st --extra-lib-dirs=$(HOME)/src/cudd-2.5.1/util

install:
	make install-hBDD
	make install-hBDD-CUDD

install-hBDD:
	cabal install

install-hBDD-CUDD:
	mkdir -p $(HOME)/src
	wget $(CUDDURL) -c -O $(CUDDFILE)
	tar xvf $(CUDDFILE) -C $(HOME)/src/
	patch $(HOME)/src/cudd-2.5.1/Makefile ./hBDD-CUDD/cudd-Makefile.patch
	cd $(HOME)/src/cudd-2.5.1/ && make
	cabal install $(CABALFLAGS)
	cd ./hBDD-CUDD && cabal install $(CABALFLAGS)
	rm -rf $(HOME)/src/hBDD
	@echo
	@echo !!! Do NOT delete the folder $(HOME)/src/cudd-2.5.1.
	@echo !!! Your hBDD-CUDD is bound to it.
	@echo

clean:
	cabal clean
	cd ./hBDD-CUDD && cabal clean