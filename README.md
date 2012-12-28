Building from Source
====================

Prerequisites
-------------

- OCaml 4 or higher <http://caml.inria.fr/download.en.html>

- Coq 8.4 <http://coq.inria.fr/download>

  Newer versions of Coq often have changes that break older
  programs. We recommend using exactly this version.

- OPAM <http://opam.ocamlpro.com>

- The cstruct library (version 0.5.3), which you can install using opam:

  ```
  $ opam install cstruct.0.5.3
  ```

- The oUnit library, which you can install using opam:

  ```
  $ opam install oUnit
  ```

Building
--------

- From the root directory of the repository, run `make`

  ```
  $ make
  ```

  Make compiles the Coq code first, extracts it to OCaml, and then compiles
  the OCaml shim.