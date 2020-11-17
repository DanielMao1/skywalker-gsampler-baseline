#ifndef __GRAPH_H__
#define __GRAPH_H__
#include <iostream>
#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "wtime.h"
#include <stdlib.h>
#include <stdint.h>
#include <sys/stat.h>
inline off_t fsize(const char *filename) {
	struct stat st; 
	if (stat(filename, &st) == 0)
		return st.st_size;
	return -1; 
}

template<
typename file_vert_t, typename file_index_t, typename file_weight_t,
typename new_vert_t, typename new_index_t, typename new_weight_t>
class graph
{
	public:
		new_index_t *beg_pos;
		new_vert_t *adj_list;
		new_weight_t *weight;
		new_vert_t *degree_list;
		new_index_t vtx_num;
		new_index_t edge_num;

	public:
		graph(){};
		~graph(){};
		graph(const char *beg_file, 
				const char *adj_list_file,
				const char *weight_file);

		graph(file_vert_t *csr,
				file_index_t *beg_pos,
				file_weight_t *weight_list,
				file_index_t vtx_num,
				file_index_t edge_num)
		{
			this->beg_pos = beg_pos;
			this->adj_list = csr;
			this->weight = weight_list;
			//this->degree_list= degree_list;
			this->edge_num = edge_num;
			this->vtx_num = vtx_num;
		};
};
#include "graph.hpp"
#endif