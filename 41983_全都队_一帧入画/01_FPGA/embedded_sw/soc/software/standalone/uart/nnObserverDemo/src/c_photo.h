#ifndef C_PHOTO_H
#define C_PHOTO_H
#include "nn_control.h"
void c_photo_capture(const nn_control_io *io);
void c_photo_preview(const nn_control_io *io);
void c_photo_release(const nn_control_io *io);
#endif
