// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * test_bfs.cu
 *
 * @brief Simple test driver program for BFS.
 */

#include <stdio.h> 
#include <string>
#include <deque>
#include <vector>
#include <iostream>

// Utilities and correctness-checking
#include <gunrock/util/test_utils.cuh>

// Graph construction utils
#include <gunrock/graphio/market.cuh>

// BFS includes
#include <gunrock/app/bfs/bfs_enactor.cuh>
#include <gunrock/app/bfs/bfs_problem.cuh>
#include <gunrock/app/bfs/bfs_functor.cuh>

// Operator includes
#include <gunrock/oprtr/edge_map_forward/kernel.cuh>
#include <gunrock/oprtr/vertex_map/kernel.cuh>

using namespace gunrock;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::bfs;


/******************************************************************************
 * Defines, constants, globals 
 ******************************************************************************/

bool g_verbose;
bool g_undirected;
bool g_quick;
bool g_stream_from_host;

/******************************************************************************
 * Housekeeping Routines
 ******************************************************************************/
 void Usage()
 {
 printf("\ntest_bfs <graph type> <graph type args> [--device=<device_index>] "
        "[--undirected] [--instrumented] [--src=<source index>] [--quick] "
        "[--num_gpus=<gpu number>] [--mark-pred] [--queue-sizing=<scale factor>]\n"
        "\n"
        "Graph types and args:\n"
        "  market [<file>]\n"
        "    Reads a Matrix-Market coordinate-formatted graph of directed/undirected\n"
        "    edges from stdin (or from the optionally-specified file).\n"
        );
 }

 /**
  * Displays the BFS result (i.e., distance from source)
  */
 template<typename VertexId, typename SizeT>
 void DisplaySolution(VertexId *source_path, VertexId *preds, SizeT nodes, bool MARK_PREDECESSORS)
 {
    printf("[");
    for (VertexId i = 0; i < nodes; ++i) {
        PrintValue(i);
        printf(":");
        PrintValue(source_path[i]);
        printf(",");
        if (MARK_PREDECESSORS)
            PrintValue(preds[i]);
        printf(" ");
    }
    printf("]\n");
 }

 /**
  * Performance/Evaluation statistics
  */

 struct Statistic
 {
    double mean;
    double m2;
    int count;

    Statistic() : mean(0.0), m2(0.0), count(0) {}

    /**
     * Updates running statistic, returning bias-corrected sample variance.
     * Online method as per Knuth.
     */
    double Update(double sample)
    {
        count++;
        double delta = sample - mean;
        mean = mean + (delta / count);
        m2 = m2 + (delta * (sample - mean));
        return m2 / (count - 1);                //bias-corrected
    }
};

/******************************************************************************
 * BFS Testing Routines
 *****************************************************************************/

 /**
  * A simple CPU-based reference BFS ranking implementation.
  */
 template<
    typename VertexId,
    typename Value,
    typename SizeT>
void SimpleReferenceBfs(
    const Csr<VertexId, Value, SizeT>       &graph,
    VertexId                                *source_path,
    VertexId                                src)
{
    //initialize distances
    for (VertexId i = 0; i < graph.nodes; ++i) {
        source_path[i] = -1;
    }
    source_path[src] = 0;
    VertexId search_depth = 0;

    // Initialize queue for managing previously-discovered nodes
    std::deque<VertexId> frontier;
    frontier.push_back(src);

    //
    //Perform BFS
    //

    CpuTimer cpu_timer;
    cpu_timer.Start();
    while (!frontier.empty()) {
        
        // Dequeue node from frontier
        VertexId dequeued_node = frontier.front();
        frontier.pop_front();
        VertexId neighbor_dist = source_path[dequeued_node] + 1;

        // Locate adjacency list
        int edges_begin = graph.row_offsets[dequeued_node];
        int edges_end = graph.row_offsets[dequeued_node + 1];

        for (int edge = edges_begin; edge < edges_end; ++edge) {
            //Lookup neighbor and enqueue if undiscovered
            VertexId neighbor = graph.column_indices[edge];
            if (source_path[neighbor] == -1) {
                source_path[neighbor] = neighbor_dist;
                if (search_depth < neighbor_dist) {
                    search_depth = neighbor_dist;
                }
                frontier.push_back(neighbor);
            }
        }
    }

    cpu_timer.Stop();
    float elapsed = cpu_timer.ElapsedMillis();
    search_depth++;

    printf("CPU BFS finished in %lf msec. Search depth is:%d\n", elapsed, search_depth);
}

/**
 * Run tests
 */
template <
    typename VertexId,
    typename Value,
    typename SizeT,
    bool INSTRUMENT,
    bool MARK_PREDECESSORS>
void RunTests(
    const Csr<VertexId, Value, SizeT> &graph,
    VertexId src,
    int max_grid_size,
    int num_gpus,
    double max_queue_sizing)
{
    typedef BFSProblem<
        VertexId,
        SizeT,
        Value,
        io::ld::cg,
        io::ld::NONE,
        io::ld::NONE,
        io::ld::cg,
        io::ld::NONE,
        io::st::cg,
        MARK_PREDECESSORS> Problem;

    typedef BFSFunctor<
        VertexId,
        SizeT,
        Value,
        Problem> Functor;


        // Allocate host-side label array (for both reference and gpu-computed results)
        VertexId    *reference_labels       = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);
        VertexId    *h_labels               = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);
        VertexId    *reference_check        = (g_quick) ? NULL : reference_labels;
        VertexId    *h_preds                = NULL;
        if (MARK_PREDECESSORS) {
            h_preds = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);
        }


        // Allocate BFS enactor map
        BFSEnactor<INSTRUMENT> bfs_enactor(g_verbose);

        // Allocate problem on GPU
        Problem *csr_problem = new Problem;
        if (csr_problem->Init(
            g_stream_from_host,
            graph.nodes,
            graph.edges,
            graph.row_offsets,
            graph.column_indices,
            num_gpus)) exit(1);

        //
        // Compute reference CPU BFS solution for source-distance
        //
        if (reference_check != NULL)
        {
            printf("compute ref value\n");
            SimpleReferenceBfs(
                    graph,
                    reference_check,
                    src);
            printf("\n");
        }

        cudaError_t         retval = cudaSuccess;

        // Perform BFS
        GpuTimer gpu_timer;

        if (retval = csr_problem->Reset(src, bfs_enactor.GetFrontierType(), max_queue_sizing)) exit(1);
        gpu_timer.Start();
        if (retval = bfs_enactor.template Enact<Problem, Functor>(csr_problem, src, max_grid_size)) exit(1);
        gpu_timer.Stop();

        if (retval && (retval != cudaErrorInvalidDeviceFunction)) {
            exit(1);
        }

        float elapsed = gpu_timer.ElapsedMillis();

        // Copy out results
        if (csr_problem->Extract(h_labels, h_preds)) exit(1);

        // Verify the result
        if (reference_check != NULL) {
            printf("Validity: ");
            CompareResults(h_labels, reference_check, graph.nodes, true);
        }
        
        // Display Solution
        DisplaySolution(h_labels, h_preds, graph.nodes, MARK_PREDECESSORS);


        // Cleanup
        if (csr_problem) delete csr_problem;
        if (reference_labels) free(reference_labels);
        if (h_labels) free(h_labels);
        if (h_preds) free(h_preds);

        cudaDeviceSynchronize();
}

template <
    typename VertexId,
    typename Value,
    typename SizeT>
void RunTests(
    Csr<VertexId, Value, SizeT> &graph,
    CommandLineArgs &args)
{
    VertexId            src                 = -1;           // Use whatever the specified graph-type's default is
    std::string         src_str;
    bool                instrumented        = false;        // Whether or not to collect instrumentation from kernels
    bool                mark_pred           = false;        // Whether or not to mark src-distance vs. parent vertices
    int                 max_grid_size       = 0;            // maximum grid size (0: leave it up to the enactor)
    int                 num_gpus            = 1;            // Number of GPUs for multi-gpu enactor to use
    double              max_queue_sizing    = 1.3;          // Maximum size scaling factor for work queues (e.g., 1.0 creates n and m-element vertex and edge frontiers).

    instrumented = args.CheckCmdLineFlag("instrumented");
    args.GetCmdLineArgument("src", src_str);
    if (src_str.empty()) {
        src = 0;
    } else {
        args.GetCmdLineArgument("src", src);
    }

    g_quick = args.CheckCmdLineFlag("quick");
    mark_pred = args.CheckCmdLineFlag("mark-pred");
    args.GetCmdLineArgument("num-gpus", num_gpus);
    args.GetCmdLineArgument("queue-sizing", max_queue_sizing);
    g_verbose = args.CheckCmdLineFlag("v");

    if (instrumented) {
        if (mark_pred) {
            RunTests<VertexId, Value, SizeT, true, true>(
                graph,
                src,
                max_grid_size,
                num_gpus,
                max_queue_sizing);
        } else {
            RunTests<VertexId, Value, SizeT, true, false>(
                graph,
                src,
                max_grid_size,
                num_gpus,
                max_queue_sizing);
        }
    } else {
        if (mark_pred) {
            RunTests<VertexId, Value, SizeT, false, true>(
                graph,
                src,
                max_grid_size,
                num_gpus,
                max_queue_sizing);
        } else {
            RunTests<VertexId, Value, SizeT, false, false>(
                graph,
                src,
                max_grid_size,
                num_gpus,
                max_queue_sizing);
        }
    }

}



/******************************************************************************
 * Main
 ******************************************************************************/

int main( int argc, char** argv)
{
	CommandLineArgs args(argc, argv);

	if ((argc < 2) || (args.CheckCmdLineFlag("help"))) {
		Usage();
		return 1;
	}

	DeviceInit(args);
	cudaSetDeviceFlags(cudaDeviceMapHost);

	//srand(0);									// Presently deterministic
	//srand(time(NULL));

	// Parse graph-contruction params
	g_undirected = args.CheckCmdLineFlag("undirected");

	std::string graph_type = argv[1];
	int flags = args.ParsedArgc();
	int graph_args = argc - flags - 1;

	if (graph_args < 1) {
		Usage();
		return 1;
	}
	
	//
	// Construct graph and perform search(es)
	//

	if (graph_type == "market") {

		// Matrix-market coordinate-formatted graph file

		typedef int VertexId;							// Use as the node identifier type
		typedef int Value;								// Use as the value type
		typedef int SizeT;								// Use as the graph size type
		Csr<VertexId, Value, SizeT> csr(false);         // default value for stream_from_host is false

		if (graph_args < 1) { Usage(); return 1; }
		char *market_filename = (graph_args == 2) ? argv[2] : NULL;
		if (graphio::BuildMarketGraph<false>(
			market_filename, 
			csr, 
			g_undirected) != 0) 
		{
			return 1;
		}

		// Run tests
		RunTests(csr, args);

	} else {

		// Unknown graph type
		fprintf(stderr, "Unspecified graph type\n");
		return 1;

	}

	return 0;
}
