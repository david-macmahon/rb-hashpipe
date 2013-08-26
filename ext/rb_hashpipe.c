/*
 * Document-module: Hashpipe
 *
 * Wraps functions provided by the Hashpipe library.
 */

/*
 * rb_hashpipe.c
 */

#include <errno.h>
#include <hashpipe_status.h>
#include <fitshead.h>

#include "ruby.h"

#define Data_Get_HPStruct(self, s) \
  Data_Get_Struct(self, hashpipe_status_t, s);

#define Data_Get_HPStruct_Ensure_Detached(self, s) \
  Data_Get_HPStruct(self, s); \
  if(s->buf) rb_raise(rb_eRuntimeError, "already attached");

#define Data_Get_HPStruct_Ensure_Attached(self, s) \
  Data_Get_HPStruct(self, s); \
  if(!s->buf) rb_raise(rb_eRuntimeError, "not attached");

/*
 * Document-class: Hashpipe::Status
 *
 * A +Status+ object encapsulates a Hashpipe status buffer.
 */

static VALUE
rb_hps_alloc(VALUE klass)
{
  hashpipe_status_t * p;
  VALUE v;
  
  v = Data_Make_Struct(klass, hashpipe_status_t, 0, free, p);
  memset(p, 0, sizeof(hashpipe_status_t));
  return v;
}

// This is called by rb_thread_blocking_region withOUT GVL.
// Returns Qtrue on error, Qfalse on OK.
static VALUE
rb_hps_attach_blocking_func(void * s)
{
  int rc;

  rc = hashpipe_status_attach(
      ((hashpipe_status_t *)s)->instance_id,
      (hashpipe_status_t *)s);

  return rc ? Qtrue : Qfalse;
}

/*
 * call-seq: Status.exists?(instance_id) -> boolean
 *
 * Returns true if the status buffer for the instance given by +instance_id+
 * already exists.
 */
VALUE rb_hps_exists(VALUE klass, VALUE vid)
{
  int id, rc;
  id = NUM2INT(vid);
  rc = hashpipe_status_exists(id);
  return rc ? Qtrue : Qfalse;
}

/*
 * call-seq: attach(instance_id, create=true) -> self
 *
 * Attaches to the status buffer of Hashpipe * instance given by +instance_id+
 * (Integer).  It is an error to call attach if already attached.  If +create+
 * is false, an exception will be raised if the specified statsu buffer does
 * not exist.
 */
VALUE rb_hps_attach(int argc, VALUE *argv, VALUE self)
{
  VALUE vid, vcreate;
  int id, create;
  VALUE vrc;
  hashpipe_status_t tmp, *s;

  rb_scan_args(argc, argv, "11", &vid, &vcreate);

  id = NUM2INT(vid);

  // Raise exception if vcreate is given and is false and specified buffer does
  // not exist.
  if(argc == 2 && !RTEST(vcreate) && !hashpipe_status_exists(id)) {
    rb_syserr_fail(ENOENT, "status buffer does not exist for given instance");
  }

  Data_Get_HPStruct_Ensure_Detached(self, s);

  // Ensure that instance_id field is set
  tmp.instance_id = id;

  vrc = rb_thread_blocking_region(
      rb_hps_attach_blocking_func, &tmp,
      RUBY_UBF_PROCESS, NULL);

  if(RTEST(vrc))
    rb_raise(rb_eRuntimeError, "could not attach to instance id %d", id);

  memcpy(s, &tmp, sizeof(hashpipe_status_t));

  return self;
}

/*
 * call-seq: Status.new(instance_id, create=true) -> Status
 *
 * Creates a Status object that is attached to the status buffer of Hashpipe
 * instance given by +instance_id+ (Integer).
 */
VALUE rb_hps_init(int argc, VALUE *argv, VALUE self)
{
  return rb_hps_attach(argc, argv, self);
}

/*
 * call-seq: detach -> self
 *
 * Detaches from the Hashpipe status buffer.  Future operations will fail until
 * attach is called.
 */
VALUE rb_hps_detach(VALUE self)
{
  int rc;
  hashpipe_status_t *s;

  Data_Get_HPStruct(self, s);

  if(s->buf) {
    rc = hashpipe_status_detach(s);

    if(rc != 0)
      rb_raise(rb_eRuntimeError, "could not detach");

    s->buf = 0;
  }

  return self;
}

/*
 * call-seq: attached? -> +true+ or +false+
 *
 * Returns true if +self+ is attached.
 */
VALUE rb_hps_attached_p(VALUE self)
{
  hashpipe_status_t *s;

  Data_Get_HPStruct(self, s);

  return s->buf ? Qtrue : Qfalse;
}

/*
 * call-seq: instance_id -> Integer (or nil)
 *
 * Returns instance ID if attached, otherwise +nil+.
 */
VALUE rb_hps_instance_id(VALUE self)
{
  hashpipe_status_t *s;

  Data_Get_HPStruct(self, s);

  return s->buf ? INT2NUM(s->instance_id) : Qnil;
}

/*
 * call-seq: unlock -> self
 *
 * Unlocks the status buffer relinguishing exclusive access.  You should always
 * unlock the status buffer after reading or modifying it.
 */
VALUE rb_hps_unlock(VALUE self)
{
  int rc;
  hashpipe_status_t *s;

  Data_Get_HPStruct_Ensure_Attached(self, s);

  rc = hashpipe_status_unlock(s);

  if(rc != 0)
    rb_raise(rb_eRuntimeError, "unlock error");

  return self;
}

// This is called by rb_thread_blocking_region withOUT GVL.
// Returns Qtrue on error, Qfalse on OK.
static VALUE
rb_hps_lock_blocking_func(void * s)
{
  int rc;
  rc = hashpipe_status_lock((hashpipe_status_t *)s);
  return rc ? Qtrue : Qfalse;
}

/*
 * call-seq: lock -> self
 *
 * Locks the status buffer for exclusive access.  You should always lock the
 * status buffer before reading or modifying it.
 */
VALUE rb_hps_lock(VALUE self)
{
  VALUE vrc;
  hashpipe_status_t *s;

  Data_Get_HPStruct_Ensure_Attached(self, s);

  vrc = rb_thread_blocking_region(
      rb_hps_lock_blocking_func, s,
      RUBY_UBF_PROCESS, NULL);

  if(RTEST(vrc))
    rb_raise(rb_eRuntimeError, "lock error");

  // If block given, yield self to the block, ensure unlock is called after
  // block finishes, and return block's return value.
  if(rb_block_given_p())
    return rb_ensure(rb_yield, self, rb_hps_unlock, self);
  else
    return self;
}

// This is called by rb_thread_blocking_region withOUT GVL.
// Returns Qnil always
static VALUE
rb_hps_clear_blocking_func(void * s)
{
  hashpipe_status_clear((hashpipe_status_t *)s);
  return Qnil;
}

/*
 * call-seq: clear! -> self
 *
 * Clears and reinitializes the status buffer.  This call locks the status
 * buffer internally so #lock need not be called prior to calling #clear!.
 */
VALUE rb_hps_clear_bang(VALUE self)
{
  hashpipe_status_t *s;

  Data_Get_HPStruct_Ensure_Attached(self, s);

  rb_thread_blocking_region(
      rb_hps_clear_blocking_func, s,
      RUBY_UBF_PROCESS, NULL);

  return self;
}

VALUE rb_hps_buf(VALUE self)
{
  int len;
  hashpipe_status_t *s;

  Data_Get_HPStruct_Ensure_Attached(self, s);
  len = gethlength(s->buf);
  return rb_str_new(s->buf, len);
}

VALUE rb_hps_length(VALUE self)
{
  hashpipe_status_t *s;
  Data_Get_HPStruct_Ensure_Attached(self, s);
  return UINT2NUM((unsigned int)gethlength(s->buf));
}

#define HGET(typecode, type, conv) \
  VALUE rb_hps_hget##typecode(VALUE self, VALUE vkey) \
  { \
    int rc; \
    type val; \
    hashpipe_status_t *s; \
    const char * key = StringValueCStr(vkey); \
    Data_Get_HPStruct_Ensure_Attached(self, s); \
    rc = hget##typecode(s->buf, key, &val); \
    return rc ? conv(val) : Qnil; \
  }

HGET(i2, short, INT2FIX)
HGET(i4, int, INT2NUM)
HGET(i8, long long, LL2NUM)
HGET(u4, unsigned int, UINT2NUM)
HGET(u8, unsigned long long, ULL2NUM)
HGET(r4, float, DBL2NUM)
HGET(r8, double, DBL2NUM)

VALUE rb_hps_hgets(VALUE self, VALUE vkey)
{
  int rc;
  char val[HASHPIPE_STATUS_RECORD_SIZE];
  hashpipe_status_t *s;
  const char * key = StringValueCStr(vkey);
  Data_Get_HPStruct_Ensure_Attached(self, s);
  rc = hgets(s->buf, key, HASHPIPE_STATUS_RECORD_SIZE, val);
  val[HASHPIPE_STATUS_RECORD_SIZE-1] = '\0';
  return rc ? rb_str_new_cstr(val) : Qnil;
}

VALUE rb_hps_delete(VALUE self, VALUE vkey)
{
  hashpipe_status_t *s;
  const char * key;
  VALUE val;

  // Get current value (to be returned)
  val = rb_hps_hgets(self, vkey);
  // If found,
  if(RTEST(val)) {
    // Delete key
    key = StringValueCStr(vkey);
    Data_Get_HPStruct_Ensure_Attached(self, s);
    hdel(s->buf, key);
  }

  return val;
}

#define HPUT(typecode, type, conv) \
  VALUE rb_hps_hput##typecode(VALUE self, VALUE vkey, VALUE vval) \
  { \
    int rc; \
    hashpipe_status_t *s; \
    const char * key = StringValueCStr(vkey); \
    type val = (type)conv(vval); \
    Data_Get_HPStruct_Ensure_Attached(self, s); \
    rc = hput##typecode(s->buf, key, val); \
    return self; \
  }

HPUT(i2, short, NUM2INT)
HPUT(i4, int, NUM2INT)
HPUT(i8, long long, NUM2LL)
HPUT(u4, unsigned int, NUM2UINT)
HPUT(u8, unsigned long long, NUM2ULL)
HPUT(r4, float, NUM2DBL)
HPUT(r8, double, NUM2DBL)

VALUE rb_hps_hputs(VALUE self, VALUE vkey, VALUE vval)
{
  int rc;
  hashpipe_status_t *s;
  const char * val = StringValueCStr(vval);
  const char * key = StringValueCStr(vkey);
  Data_Get_HPStruct_Ensure_Attached(self, s);
  rc = hputs(s->buf, key, val);
  if(rc)
    // Currently, the only error return is if header length is exceeded
    rb_raise(rb_eRuntimeError, "header length exceeded");

  return self;
}

#define HGET_METHOD(klass, typecode) \
  rb_define_method(klass, "hget"#typecode, rb_hps_hget##typecode, 1);

#define HPUT_METHOD(klass, typecode) \
  rb_define_method(klass, "hput"#typecode, rb_hps_hput##typecode, 2);

void Init_hashpipe()
{
  VALUE mHashpipe;
  VALUE cStatus;

  mHashpipe = rb_define_module("Hashpipe");
  cStatus = rb_define_class_under(mHashpipe, "Status", rb_cObject);

  // RECORD_SIZE constant
  rb_define_const(cStatus, "RECORD_SIZE",
      INT2FIX(HASHPIPE_STATUS_RECORD_SIZE));

  rb_define_alloc_func(cStatus, rb_hps_alloc);
  rb_define_singleton_method(cStatus, "exists?", rb_hps_exists, 1);
  rb_define_method(cStatus, "initialize", rb_hps_init, -1);
  rb_define_method(cStatus, "attach", rb_hps_attach, -1);
  rb_define_method(cStatus, "detach", rb_hps_detach, 0);
  rb_define_method(cStatus, "attached?", rb_hps_attached_p, 0);
  rb_define_method(cStatus, "instance_id", rb_hps_instance_id, 0);
  rb_define_method(cStatus, "unlock", rb_hps_unlock, 0);
  rb_define_method(cStatus, "lock", rb_hps_lock, 0);
  rb_define_method(cStatus, "clear!", rb_hps_clear_bang, 0);
  rb_define_method(cStatus, "delete", rb_hps_delete, 1);
  rb_define_method(cStatus, "buf", rb_hps_buf, 0);
  rb_define_method(cStatus, "length", rb_hps_length, 0);

  // hget methods
  HGET_METHOD(cStatus, i2);
  HGET_METHOD(cStatus, i4);
  HGET_METHOD(cStatus, i8);
  HGET_METHOD(cStatus, u4);
  HGET_METHOD(cStatus, u8);
  HGET_METHOD(cStatus, r4);
  HGET_METHOD(cStatus, r8);
  HGET_METHOD(cStatus, s);

  // hput methods
  HPUT_METHOD(cStatus, i2);
  HPUT_METHOD(cStatus, i4);
  HPUT_METHOD(cStatus, i8);
  HPUT_METHOD(cStatus, u4);
  HPUT_METHOD(cStatus, u8);
  HPUT_METHOD(cStatus, r4);
  HPUT_METHOD(cStatus, r8);
  HPUT_METHOD(cStatus, s);
}
