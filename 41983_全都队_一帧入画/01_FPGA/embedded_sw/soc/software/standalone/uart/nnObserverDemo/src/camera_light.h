#ifndef CAMERA_LIGHT_H
#define CAMERA_LIGHT_H
#include "nn_control.h"
void camera_light_service(const nn_control_io *io);
int camera_light_dispatch(const nn_control_io *io,const char *line);
#endif
