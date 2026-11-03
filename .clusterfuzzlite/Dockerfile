FROM gcr.io/oss-fuzz-base/base-builder-ruby@sha256:49cc7137a2816eab92d069f2419a124cabf66263ff318d65c9597d88f0b401e6

COPY . $SRC/dalli
COPY .clusterfuzzlite/build.sh $SRC/
WORKDIR $SRC/dalli
