#ifndef C_SYSTEM_H
#define C_SYSTEM_H
#include "nn_control.h"
extern unsigned c_camera_ready,c_camera_error,c_camera_index,c_system_config;
unsigned c_camera_resume(const nn_control_io *io);
unsigned c_camera_init(const nn_control_io *io);
unsigned c_camera_read(const nn_control_io *io,unsigned addr,unsigned *data);
unsigned c_camera_write(const nn_control_io *io,unsigned addr,unsigned data);
unsigned c_system_ui(const nn_control_io *io,unsigned tag,unsigned enable);
unsigned c_system_style(const nn_control_io *io,unsigned model,unsigned buttons);
unsigned c_system_roi(const nn_control_io *io,unsigned mode);
unsigned c_system_fish(const nn_control_io *io,unsigned enable,unsigned buttons);
unsigned c_weights_load(const nn_control_io *io);
#endif
