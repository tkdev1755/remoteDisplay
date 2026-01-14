# Nom de la bibliothèque
LIB_NAME = libkeychain.so

# Fichiers source
SRC = linuxKeychain.c

# Flags pour gcc
CFLAGS = -fPIC -Wall -Wextra -O2
LDFLAGS = -shared
PKGCONFIG = $(shell pkg-config --cflags --libs libsecret-1)

# Commande de compilation
$(LIB_NAME): $(SRC)
	gcc $(CFLAGS) $(LDFLAGS) -o $@ $^ $(PKGCONFIG)

# Nettoyage
clean:
	rm -f $(LIB_NAME)

# Par défaut, build
all: $(LIB_NAME)
