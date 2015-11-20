
CUDDGIT = https://github.com/adamwalker/cudd.git

CUDDDIR = /usr/local/cudd

CABALFLAGS = --reinstall --force-reinstalls

install:
	make install-cudd
	make install-hBDD
	make install-hBDD-CUDD

install-cudd:
	mkdir -p ./dist/cudd
	if [ ! -d ./dist/cudd/.git ] ; \
	then git clone https://github.com/adamwalker/cudd.git ./dist/cudd ; \
	else cd ./dist/cudd && git pull ; \
	fi ;
	cd ./dist/cudd/ && make -f Makefile.64bit libso
	@echo "Please allow me to copy cudd to /usr/local/cudd"
	sudo cp -Lvr ./dist/cudd/include/* /usr/local/cudd/include/
	sudo cp -Lvr ./dist/cudd/libso/* /usr/local/cudd/libso/

install-hBDD:
	cabal install $(CABALFLAGS)

install-hBDD-CUDD:
	cd ./hBDD-CUDD && cabal install $(CABALFLAGS)

clean:
	cabal clean
	cd ./hBDD-CUDD && cabal clean
