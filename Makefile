
CUDDGIT = https://github.com/adamwalker/cudd.git

CUDDDIR = $(HOME)/src/cudd

CABALFLAGS = --reinstall --force-reinstalls --extra-include-dirs=$(CUDDDIR)/include --extra-lib-dirs=$(CUDDDIR)/libso

install:
	make install-hBDD
	make install-hBDD-CUDD

install-hBDD:
	cabal install --force-reinstalls

install-hBDD-CUDD:
	mkdir -p $(CUDDDIR)
	if [ ! -d $(CUDDDIR)/.git ] ; \
	then git clone https://github.com/adamwalker/cudd.git $(HOME)/src/cudd ; \
	else cd $(CUDDDIR) && git pull ; \
	fi ;
	cd $(CUDDDIR) && make -f Makefile.64bit libso
	cd ./hBDD-CUDD && cabal install $(CABALFLAGS)
	@echo
	@echo !!! Do NOT delete the folder $(CUDDDIR)
	@echo !!! Your hBDD-CUDD is bound to it.
	@echo

clean:
	cabal clean
	cd ./hBDD-CUDD && cabal clean
