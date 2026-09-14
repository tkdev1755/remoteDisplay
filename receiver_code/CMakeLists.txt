cmake_minimum_required(VERSION 3.13)
project(remotedisplay_receiver LANGUAGES CXX)

# Build autonome de receiver_app : plus aucune dépendance à Flutter/GTK.
# Sert de "brique" réutilisable — l'installeur (à venir) copie juste le binaire
# produit ici, il n'a besoin ni du SDK Dart ni de la toolchain Flutter.
#
# Utilisation :
#   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j
#   ./build/receiver_app --debug

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_FLAGS_RELEASE "-O3")

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 REQUIRED sdl2)
find_package(Threads REQUIRED) # thread réseau + thread affichage

add_executable(receiver_app receiver.cpp)
target_include_directories(receiver_app PRIVATE ${SDL2_INCLUDE_DIRS})
target_link_directories(receiver_app PRIVATE ${SDL2_LIBRARY_DIRS})
target_link_libraries(receiver_app PRIVATE ${SDL2_LIBRARIES} Threads::Threads)

# -march=native gagne quelques % sur le memcpy/recvmmsg, mais lie le binaire au
# CPU qui compile. Désactivable pour builder sur une machine et déployer sur une
# autre (même famille de CPU) : -DPORTABLE=ON
option(PORTABLE "Ne pas utiliser -march=native (build reproductible / déployable ailleurs)" OFF)
if(NOT PORTABLE)
  target_compile_options(receiver_app PRIVATE -march=native)
endif()

install(TARGETS receiver_app RUNTIME DESTINATION bin)
