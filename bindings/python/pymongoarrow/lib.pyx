# Copyright 2021-present MongoDB, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Cython compiler directives
# distutils: language=c++
# cython: language_level=3

# Stdlib imports
import copy
import datetime
import enum

# Python imports
import numpy as np
from pyarrow import timestamp, struct
from pymongoarrow.types import _BsonArrowTypes
from pymongoarrow.errors import InvalidBSON, PyMongoArrowError

# Cython imports
from cpython cimport PyBytes_Size, object
from cython.operator cimport dereference
from libcpp cimport bool as cbool
from libcpp.map cimport map
from libcpp.vector cimport vector
from libcpp.string cimport string
from libc.stdlib cimport malloc, free
from pyarrow.lib cimport *
from pyarrow.lib import tobytes, StructType
from pymongoarrow.libarrow cimport *
from pymongoarrow.libbson cimport *
from pymongoarrow.types import _BsonArrowTypes, _atypes


# libbson version
libbson_version = bson_get_version().decode('utf-8')

# BSON tools

cdef const bson_t* bson_reader_read_safe(bson_reader_t* stream_reader) except? NULL:
    cdef cbool reached_eof = False
    cdef const bson_t* doc = bson_reader_read(stream_reader, &reached_eof)
    if doc == NULL and reached_eof is False:
        raise InvalidBSON("Could not read BSON document stream")
    return doc

_builder_type_map = {
    0x10: Int32Builder,
    0x12: Int64Builder,
    0x01: DoubleBuilder,
    0x09: DatetimeBuilder,
    0x07: ObjectIdBuilder,
    0x02: StringBuilder,
    0x08: BoolBuilder,
    0x03: DocumentBuilder,
    0x13: StringBuilder
}


cdef char *_decimal128_str = <char *> malloc(
        BSON_DECIMAL128_STRING * sizeof(char))


cdef get_builder(bson_iter_t doc_iter, context):
    cdef bson_type_t value_t
    cdef bson_iter_t doc_iter_copy

    value_t = bson_iter_type(&doc_iter)
    if value_t not in _builder_type_map:
        return

    builder_type = _builder_type_map[value_t]
    if builder_type == DatetimeBuilder and context.tzinfo is not None:
        arrow_type = timestamp('ms', tz=context.tzinfo)
        return DatetimeBuilder(dtype=arrow_type)

    if builder_type == DocumentBuilder:
        doc_iter_copy = doc_iter
        struct_dtype = extract_document_dtype(&doc_iter_copy, context)
        return DocumentBuilder(struct_dtype)

    return builder_type()


cdef extract_document_dtype(bson_iter_t * doc_iter, context):
    # TODO: auto-discovery for documents
    # TODO: test all of the _BsonArrowTypes
    pass


cdef handle_value(builder, bson_iter_t * doc_iter):
    cdef uint32_t str_len
    cdef const uint8_t *doc_buf = NULL
    cdef uint32_t doc_buf_len = 0;
    cdef bson_decimal128_t dec128
    cdef bson_type_t value_t
    cdef const char * bson_str

    # Alias types
    t_int32 = _BsonArrowTypes.int32
    t_int64 = _BsonArrowTypes.int64
    t_double = _BsonArrowTypes.double
    t_datetime = _BsonArrowTypes.datetime
    t_oid = _BsonArrowTypes.objectid
    t_string = _BsonArrowTypes.string
    t_bool = _BsonArrowTypes.bool
    t_document = _BsonArrowTypes.document

    ftype = builder.type_marker
    value_t = bson_iter_type(doc_iter)
    if ftype == t_int32:
        if value_t == BSON_TYPE_INT32:
            builder.append(bson_iter_int32(doc_iter))
        else:
            builder.append_null()
    elif ftype == t_int64:
        if (value_t == BSON_TYPE_INT64 or
                value_t == BSON_TYPE_BOOL or
                value_t == BSON_TYPE_DOUBLE or
                value_t == BSON_TYPE_INT32):
            builder.append(bson_iter_as_int64(doc_iter))
        else:
            builder.append_null()
    elif ftype == t_oid:
        if value_t == BSON_TYPE_OID:
            builder.append(<bytes>(<uint8_t*>bson_iter_oid(doc_iter))[:12])
        else:
            builder.append_null()
    elif ftype == t_string:
        if value_t == BSON_TYPE_UTF8:
            bson_str = bson_iter_utf8(doc_iter, &str_len)
            builder.append(<bytes>(bson_str)[:str_len])
        elif value_t == BSON_TYPE_DECIMAL128:
            bson_iter_decimal128(doc_iter, &dec128)
            bson_decimal128_to_string(&dec128, _decimal128_str)
            builder.append(<bytes>(_decimal128_str))
        else:
            builder.append_null()
    elif ftype == t_double:
        if (value_t == BSON_TYPE_DOUBLE or
                value_t == BSON_TYPE_BOOL or
                value_t == BSON_TYPE_INT32 or
                value_t == BSON_TYPE_INT64):
            builder.append(bson_iter_as_double(doc_iter))
        else:
            builder.append_null()
    elif ftype == t_datetime:
        if value_t == BSON_TYPE_DATE_TIME:
            builder.append(bson_iter_date_time(doc_iter))
        else:
            builder.append_null()
    elif ftype == t_bool:
        if value_t == BSON_TYPE_BOOL:
            builder.append(bson_iter_bool(doc_iter))
        else:
            builder.append_null()
    elif ftype == t_document:
        if value_t == BSON_TYPE_DOCUMENT:
            bson_iter_document(doc_iter, &doc_buf_len, &doc_buf)
            builder.append(<bytes>doc_buf[doc_buf_len])
        else:
            builder.append_null()
    else:
        raise PyMongoArrowError('unknown ftype {}'.format(ftype))


def process_bson_stream(bson_stream, context):
    cdef const uint8_t* docstream = <const uint8_t *>bson_stream
    cdef size_t length = <size_t>PyBytes_Size(bson_stream)
    cdef bson_reader_t* stream_reader = bson_reader_new_from_data(docstream, length)
    cdef StructType struct_dtype
    cdef const bson_t * doc = NULL
    cdef bson_iter_t doc_iter
    cdef bson_iter_t doc_iter_copy
    cdef const char* key
    cdef Py_ssize_t count = 0

    builder_map = context.builder_map

    # initialize count to current length of builders
    for _, builder in builder_map.items():
        count = len(builder)
        break

    try:
        while True:
            doc = bson_reader_read_safe(stream_reader)
            if doc == NULL:
                break
            if not bson_iter_init(&doc_iter, doc):
                raise InvalidBSON("Could not read BSON document")
            while bson_iter_next(&doc_iter):
                key = bson_iter_key(&doc_iter)
                builder = builder_map.get(key)
                if builder is None and context.schema is None:
                    doc_iter_copy = doc_iter
                    builder = get_builder(doc_iter_copy, context)
                    if not builder:
                        continue
                    builder_map[key] = builder
                    for _ in range(count):
                        builder.append_null()

                if builder is not None:
                    doc_iter_copy = doc_iter
                    handle_value(builder, &doc_iter)
            count += 1
            for _, builder in builder_map.items():
                if len(builder) != count:
                    # Append null to account for any missing field(s)
                    builder.append_null()
    finally:
        bson_reader_destroy(stream_reader)


# Builders

cdef class _ArrayBuilderBase:

    def append_values(self, values):
        for value in values:
            if value is None or value is np.nan:
                self.append_null()
            else:
                self.append(value)


cdef class StringBuilder(_ArrayBuilderBase):
    type_marker = _BsonArrowTypes.string
    cdef:
        shared_ptr[CStringBuilder] builder

    def __cinit__(self, MemoryPool memory_pool=None):
        cdef CMemoryPool* pool = maybe_unbox_memory_pool(memory_pool)
        self.builder.reset(new CStringBuilder(pool))

    def __len__(self):
        return self.builder.get().length()

    cpdef append_null(self):
        self.builder.get().AppendNull()

    cpdef append(self, value):
        self.builder.get().Append(tobytes(value))

    cpdef finish(self):
        cdef shared_ptr[CArray] out
        with nogil:
            self.builder.get().Finish(&out)
        return pyarrow_wrap_array(out)

    cdef shared_ptr[CStringBuilder] unwrap(self):
        return self.builder


cdef class ObjectIdBuilder(_ArrayBuilderBase):
    type_marker = _BsonArrowTypes.objectid
    cdef:
        shared_ptr[CFixedSizeBinaryBuilder] builder

    def __cinit__(self, MemoryPool memory_pool=None):
        cdef shared_ptr[CDataType] dtype = fixed_size_binary(12)
        cdef CMemoryPool* pool = maybe_unbox_memory_pool(memory_pool)
        self.builder.reset(new CFixedSizeBinaryBuilder(dtype, pool))

    cpdef append_null(self):
        self.builder.get().AppendNull()

    def __len__(self):
        return self.builder.get().length()

    cpdef append(self, value):
        self.builder.get().Append(value)

    cpdef finish(self):
        cdef shared_ptr[CArray] out
        with nogil:
            self.builder.get().Finish(&out)
        return pyarrow_wrap_array(out)

    cdef shared_ptr[CFixedSizeBinaryBuilder] unwrap(self):
        return self.builder


cdef class Int32Builder(_ArrayBuilderBase):
    type_marker = _BsonArrowTypes.int32
    cdef:
        shared_ptr[CInt32Builder] builder

    def __cinit__(self, MemoryPool memory_pool=None):
        cdef CMemoryPool* pool = maybe_unbox_memory_pool(memory_pool)
        self.builder.reset(new CInt32Builder(pool))

    cpdef append_null(self):
        self.builder.get().AppendNull()

    def __len__(self):
        return self.builder.get().length()

    cpdef append(self, value):
        self.builder.get().Append(value)

    cpdef finish(self):
        cdef shared_ptr[CArray] out
        with nogil:
            self.builder.get().Finish(&out)
        return pyarrow_wrap_array(out)

    cdef shared_ptr[CInt32Builder] unwrap(self):
        return self.builder


cdef class Int64Builder(_ArrayBuilderBase):
    type_marker = _BsonArrowTypes.int64
    cdef:
        shared_ptr[CInt64Builder] builder

    def __cinit__(self, MemoryPool memory_pool=None):
        cdef CMemoryPool* pool = maybe_unbox_memory_pool(memory_pool)
        self.builder.reset(new CInt64Builder(pool))

    cpdef append_null(self):
        self.builder.get().AppendNull()

    def __len__(self):
        return self.builder.get().length()

    cpdef append(self, value):
        self.builder.get().Append(value)

    cpdef finish(self):
        cdef shared_ptr[CArray] out
        with nogil:
            self.builder.get().Finish(&out)
        return pyarrow_wrap_array(out)

    cdef shared_ptr[CInt64Builder] unwrap(self):
        return self.builder


cdef class DoubleBuilder(_ArrayBuilderBase):
    type_marker = _BsonArrowTypes.double
    cdef:
        shared_ptr[CDoubleBuilder] builder

    def __cinit__(self, MemoryPool memory_pool=None):
        cdef CMemoryPool* pool = maybe_unbox_memory_pool(memory_pool)
        self.builder.reset(new CDoubleBuilder(pool))

    cpdef append_null(self):
        self.builder.get().AppendNull()

    def __len__(self):
        return self.builder.get().length()

    cpdef append(self, value):
        self.builder.get().Append(value)

    cpdef finish(self):
        cdef shared_ptr[CArray] out
        with nogil:
            self.builder.get().Finish(&out)
        return pyarrow_wrap_array(out)

    cdef shared_ptr[CDoubleBuilder] unwrap(self):
        return self.builder


cdef class DatetimeBuilder(_ArrayBuilderBase):
    type_marker = _BsonArrowTypes.datetime
    cdef:
        shared_ptr[CTimestampBuilder] builder
        TimestampType dtype

    def __cinit__(self, TimestampType dtype=timestamp('ms'),
                  MemoryPool memory_pool=None):
        cdef CMemoryPool* pool = maybe_unbox_memory_pool(memory_pool)
        if dtype.unit != 'ms':
            raise TypeError("PyMongoArrow only supports millisecond "
                            "temporal resolution compatible with MongoDB's "
                            "UTC datetime type.")
        self.dtype = dtype
        self.builder.reset(new CTimestampBuilder(
            pyarrow_unwrap_data_type(self.dtype), pool))

    cpdef append_null(self):
        self.builder.get().AppendNull()

    def __len__(self):
        return self.builder.get().length()

    cpdef append(self, value):
        self.builder.get().Append(value)

    cpdef finish(self):
        cdef shared_ptr[CArray] out
        with nogil:
            self.builder.get().Finish(&out)
        return pyarrow_wrap_array(out)

    @property
    def unit(self):
        return self.dtype

    cdef shared_ptr[CTimestampBuilder] unwrap(self):
        return self.builder


cdef class BoolBuilder(_ArrayBuilderBase):
    type_marker = _BsonArrowTypes.bool
    cdef:
        shared_ptr[CBooleanBuilder] builder

    def __cinit__(self, MemoryPool memory_pool=None):
        cdef CMemoryPool* pool = maybe_unbox_memory_pool(memory_pool)
        self.builder.reset(new CBooleanBuilder(pool))

    cpdef append_null(self):
        self.builder.get().AppendNull()

    def __len__(self):
        return self.builder.get().length()

    cpdef append(self, value):
        self.builder.get().Append(<c_bool>value)

    cpdef finish(self):
        cdef shared_ptr[CArray] out
        with nogil:
            self.builder.get().Finish(&out)
        return pyarrow_wrap_array(out)

    cdef shared_ptr[CBooleanBuilder] unwrap(self):
        return self.builder



cdef get_field_builder(field):
    field_type = field.type
    if _atypes.is_int32(field_type):
        field_builder = Int32Builder()
    elif _atypes.is_int64(field_type):
        field_builder = Int64Builder()
    elif _atypes.is_float64(field_type):
        field_builder = DoubleBuilder()
    elif _atypes.is_timestamp(field_type):
        field_builder = DatetimeBuilder(field_type)
    elif _atypes.is_string(field_type):
        field_builder = StringBuilder()
    elif _atypes.is_boolean(field_type):
        field_builder = BoolBuilder()
    elif _atypes.is_struct(field_type):
        field_builder = DocumentBuilder(field_type)
    elif getattr(field_type, '_type_marker') == _BsonArrowTypes.objectid:
        field_builder = ObjectIdBuilder()
    elif getattr(field_type, '_type_marker') == _BsonArrowTypes.decimal128_str:
        field_builder = StringBuilder()
    else:
        field_builder = StringBuilder()
    return field_builder()


cdef class DocumentBuilder(_ArrayBuilderBase):
    type_marker = _BsonArrowTypes.struct
    field_builders = []
    cdef:
        shared_ptr[CStructBuilder] builder
        StructType dtype
        vector[shared_ptr[CArrayBuilder]] c_field_builders

    #  https://github.com/apache/arrow/blob/31a07be1d9dc2f7c9720cc0fdcd7f083d947aba1/cpp/src/arrow/array/builder_nested.h#L487
    # Append an element to the Struct. All child-builders' Append method must
    # be called independently to maintain data-structure consistency.

    # We want to make a struct builder that allows adding homogeneous
    # recursive nested documents.

    # Use https://github.com/mongodb-labs/mongo-arrow/pull/91/files#diff-4bebdbb1fb3a226fc1c92ec68a1472b09b4a8b8362f49db23529af97f126b3c2
    # for some of the Cython code.

    def __cinit__(self, StructType dtype, MemoryPool memory_pool=None):
        if not isinstance(dtype, StructType):
            raise ValueError("dtype must be a struct()")
        cdef StringBuilder field_builder
        self.dtype = dtype
        for field in dtype:
            field_builder = get_field_builder(field)
            self.builders.append(field_builder)
            self.c_field_builders.push_back(<shared_ptr[CArrayBuilder]>field_builder.builder)

        cdef CMemoryPool* pool = maybe_unbox_memory_pool(memory_pool)
        self.builder.reset(new CStructBuilder(pyarrow_unwrap_data_type(self.dtype), pool, self.c_field_builders))

    @property
    def dtype(self):
        return self.dtype

    cdef append_null(self):
        self.builder.get().AppendNull()

    def __len__(self):
        return self.builder.get().length()

    cdef append(self, value):
        # TODO: extract the document from the bytes and append the values
        # to the field builders.
        # TODO: Add a test to test builders
        self.builder.get().Append(True)

    cpdef finish(self):
        cdef shared_ptr[CArray] out
        with nogil:
            self.builder.get().Finish(&out)
        return pyarrow_wrap_array(out)

    cdef shared_ptr[CStructBuilder] unwrap(self):
        return self.builder
