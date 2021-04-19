#!/bin/bash -ex

set -o xtrace
set -o errexit

# Ensure we are in the correct working directory
if [ ! -d "$(pwd)/pymongoarrow" ] || [ ! -e "$(pwd)/setup.py" ]
then
  echo "PyMongoArrow sources not found at expected location"
  exit 1
fi

# Build libbson binaries in $(pwd)/libbson
LIBBSON_INSTALL_DIR="$(pwd)/libbson"

# Platform-dependent actions:
# - Compute shared library name
# - Set Python runtime to use
if [ "Darwin" = "$(uname -s)" ]
then
  LIBBSON_SO="libbson-1.0.0.dylib"
  PYTHON=${PYTHON_BINARY:-"python"}
elif [ "Linux" = "$(uname -s)" ]
then
  LIBBSON_SO="libbson-1.0.so.0"
  PYTHON=${PYTHON_BINARY:-"python3"}
else
  echo "Unsupported platform"
fi

# Build libbson
LIBBSON_INSTALL_DIR="$LIBBSON_INSTALL_DIR" LIBBSON_VERSION=${LIBBSON_VERSION:-""} ./build-libbson.sh

# Print Python version used
$PYTHON --version

# Vendor libbson shared library in PyMongoArrow wheels
cp $LIBBSON_INSTALL_DIR/lib*/$LIBBSON_SO "$(pwd)/pymongoarrow/"

# Install build dependencies
$PYTHON -m pip install -U pip setuptools wheel
$PYTHON -m pip install "Cython>=0.29" "pyarrow>=3,<3.1"

# https://arrow.apache.org/docs/python/extending.html#building-extensions-against-pypi-wheels
$PYTHON -c "import pyarrow; pyarrow.create_library_symlinks()"

# Build wheels in $(pwd)/dist/*.whl
LIBBSON_INSTALL_DIR="$LIBBSON_INSTALL_DIR" $PYTHON setup.py bdist_wheel
