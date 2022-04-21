/*
  OpenCL Kernel capable of wraping an image
  to an equirectangular projection using a Thin
  Plate Spline transformation that was already
  solved on the CPU.

  This has a huge performance boost over doing
  it purely on CPU, unless you have a potato
  as a GPU of course!

  The TPS code is nearly a 1:1 port of Vizz's
  in C++. Only 2D is supported as realistically
  for any usecase worth doing on GPU... It will
  be 2D.

  This is the 32-bits float (float) version,
  which allows using the more common (for consumer
  cards) FP32 cores.
*/

inline float SQ(const float x) { return x * x; }

inline void VizGeorefSpline2DBase_func4(float *res, const float *pxy,
                                        global const float *xr, global const float *yr) {
  float dist0 = SQ(xr[0] - pxy[0]) + SQ(yr[0] - pxy[1]);
  res[0] = dist0 != 0.0 ? dist0 * log(dist0) : 0.0;
  float dist1 = SQ(xr[1] - pxy[0]) + SQ(yr[1] - pxy[1]);
  res[1] = dist1 != 0.0 ? dist1 * log(dist1) : 0.0;
  float dist2 = SQ(xr[2] - pxy[0]) + SQ(yr[2] - pxy[1]);
  res[2] = dist2 != 0.0 ? dist2 * log(dist2) : 0.0;
  float dist3 = SQ(xr[3] - pxy[0]) + SQ(yr[3] - pxy[1]);
  res[3] = dist3 != 0.0 ? dist3 * log(dist3) : 0.0;
}

inline float VizGeorefSpline2DBase_func(const float x1, const float y1,
                                        const float x2, const float y2) {
  const float dist = SQ(x2 - x1) + SQ(y2 - y1);
  return dist != 0.0 ? dist * log(dist) : 0.0;
}

void kernel warp_image_thin_plate_spline(
    global ushort *map_image, global ushort *img, global int *tps_no_points,
    global float *tps_x, global float *tps_y, global float *tps_coef_1,
    global float *tps_coef_2, global float *tps_xmean, global float *tps_ymean,
    global int *img_settings) {

  int id = get_global_id(0);
  int nthreads = get_global_size(0);

  int map_img_width = img_settings[0];
  int map_img_height = img_settings[1];
  int crop_width = img_settings[8] - img_settings[7];
  int crop_height = img_settings[6] - img_settings[5];
  int img_width = img_settings[2];
  int img_height = img_settings[3];
  int img_channels = img_settings[4];

  size_t n = crop_width * crop_height;

  size_t ratio = (n / nthreads); // number of elements for each thread
  size_t start = ratio * id;
  size_t stop = ratio * (id + 1);

  // Init TPS

  float xx, yy;

  float vars[2];
  global float *coef[2] = {tps_coef_1, tps_coef_2};
  int _nof_points = *tps_no_points;
  int _nof_vars = 2;
  float x_mean = *tps_xmean;
  float y_mean = *tps_ymean;

  for (size_t xy_ptr = start; xy_ptr < stop; xy_ptr++) {
    int x = (xy_ptr % crop_width);
    int y = (xy_ptr / crop_width);

    // Scale to the map
    float lat =
        -((float)(y + img_settings[5]) / (float)map_img_height) * 180 + 90;
    float lon =
        ((float)(x + img_settings[7]) / (float)map_img_width) * 360 - 180;

    // Perform TPS
    {
      const float Pxy[2] = {lon - x_mean, lat - y_mean};
      for (int v = 0; v < _nof_vars; v++)
        vars[v] = coef[v][0] + coef[v][1] * Pxy[0] + coef[v][2] * Pxy[1];

      int r = 0; // Used after for.
      for (; r < (_nof_points & (~3)); r += 4) {
        float dfTmp[4] = {};
        VizGeorefSpline2DBase_func4(dfTmp, Pxy, &tps_x[r], &tps_y[r]);
        for (int v = 0; v < _nof_vars; v++)
          vars[v] += coef[v][r + 3] * dfTmp[0] + coef[v][r + 3 + 1] * dfTmp[1] +
                     coef[v][r + 3 + 2] * dfTmp[2] +
                     coef[v][r + 3 + 3] * dfTmp[3];
      }
      for (; r < _nof_points; r++) {
        const float tmp =
            VizGeorefSpline2DBase_func(Pxy[0], Pxy[1], tps_x[r], tps_y[r]);
        for (int v = 0; v < _nof_vars; v++)
          vars[v] += coef[v][r + 3] * tmp;
      }

      xx = vars[0];
      yy = vars[1];
    }

    if (xx < 0 || yy < 0)
      continue;

    if ((int)xx > img_width - 1 || (int)yy > img_height - 1)
      continue;

    for (int c = 0; c < img_channels; c++)
      map_image[(crop_width * crop_height) * c + y * crop_width + x] =
          img[(img_width * img_height) * c + (int)yy * img_width + (int)xx];
  }
}