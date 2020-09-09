const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const nitori = @import("nitori");

const communication = nitori.communication;
const Channel = communication.Channel;
const EventChannel = communication.EventChannel;

const ng = nitori.graph;
const Graph = ng.Graph;
const NodeIndex = ng.NodeIndex;
const EdgeIndex = ng.EdgeIndex;

//;

const module = @import("module.zig");
const Module = module.Module;

const system = @import("system.zig");
const CallbackContext = system.CallbackContext;

//;

pub const max_callback_len: usize = 2048;

pub const GraphModule = struct {
    module: Module,
    // TODO change this to a ptr / allocate and own it
    buffer: [max_callback_len]f32,
};

// TODO move this to module.zig maybe
pub const InBuffer = struct {
    id: usize,
    buf: []const f32,
};

//;

fn cloneArrayList(comptime T: type, allocator: *Allocator, alist: ArrayList(T)) !ArrayList(T) {
    var ret = try ArrayList(T).initCapacity(allocator, alist.capacity);
    ret.items.len = alist.items.len;
    for (alist.items) |item, i| ret.items[i] = item;
    return ret;
}

//;

// ptrs can be shared between audio thread and main thread,
//   audio thread is the only one modifying and accessing the ptrs
//     after theyve been allocated on main thread, then swapped atomically
//     freed by main thread
pub const AudioGraphBase = struct {
    const Self = @This();

    allocator: *Allocator,

    modules: ArrayList(GraphModule),
    graph: Graph(usize, usize),
    sorted: []NodeIndex,
    output: ?NodeIndex,

    temp_in_bufs: ArrayList(InBuffer),
    removals: ArrayList(usize),

    fn init(allocator: *Allocator) Self {
        const graph = Graph(usize, usize).init(allocator);
        return .{
            .allocator = allocator,
            .modules = ArrayList(GraphModule).init(allocator),
            .graph = graph,
            .sorted = graph.toposort(allocator, allocator) catch unreachable,
            .output = null,
            .temp_in_bufs = ArrayList(InBuffer).init(allocator),
            .removals = ArrayList(usize).init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        self.removals.deinit();
        self.temp_in_bufs.deinit();
        self.allocator.free(self.sorted);
        self.modules.deinit();
        self.graph.deinit();
    }

    //!

    fn sort(self: *Self, workspace_allocator: *Allocator) !void {
        self.sorted = try self.graph.toposort(self.allocator, workspace_allocator);
    }

    // clones using allocator sent on init
    fn clone(self: Self) !Self {
        var ret: Self = undefined;
        ret.allocator = self.allocator;
        ret.modules = try cloneArrayList(GraphModule, self.allocator, self.modules);
        errdefer ret.modules.deinit();
        ret.graph = try self.graph.clone(self.allocator);
        errdefer ret.graph.deinit();
        ret.sorted = try self.allocator.dupe(NodeIndex, self.sorted);
        errdefer self.allocator.free(ret.sorted);
        ret.output = self.output;
        ret.temp_in_bufs = try cloneArrayList(InBuffer, self.allocator, self.temp_in_bufs);
        errdefer ret.temp_in_bufs.deinit();
        ret.removals = try cloneArrayList(usize, self.allocator, self.removals);
        return ret;
    }
};

// Audio-thread side audio graph
// nothing should or needs to support reallocation
pub const AudioGraph = struct {
    const Self = @This();

    base: AudioGraphBase,

    tx: Channel(AudioGraphBase).Sender,
    rx: EventChannel(AudioGraphBase).Receiver,

    // allocator must be the same as used for the controller
    pub fn init(
        allocator: *Allocator,
        channel: *Channel(AudioGraphBase),
        event_channel: *EventChannel(AudioGraphBase),
    ) Self {
        return .{
            .base = AudioGraphBase.init(allocator),
            .tx = channel.makeSender(),
            .rx = event_channel.makeReceiver(),
        };
    }

    // deinit is called after audio thread is killed
    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }

    //;

    // TODO move to base
    fn moduleIdxFromNodeIdx(self: Self, idx: NodeIndex) usize {
        return self.base.graph.nodes.items[idx].weight;
    }

    pub fn frame(self: *Self, ctx: CallbackContext) void {
        if (self.rx.tryRecv(ctx.now)) |*swap_ev| {
            std.mem.swap(AudioGraphBase, &self.base, &swap_ev.data);
            std.mem.swap(ArrayList(usize), &self.base.removals, &swap_ev.data.removals);
            // TODO theres an error here for if channel is full
            self.tx.send(swap_ev.data) catch unreachable;
        }

        for (self.base.sorted) |idx| {
            const module_idx = self.moduleIdxFromNodeIdx(idx);
            self.base.modules.items[module_idx].module.frame(ctx);
        }
    }

    // TODO handle buffer max len more robustly
    //   as is, out param can be any size
    pub fn compute(self: *Self, ctx: CallbackContext, out: []f32) void {
        if (self.base.output) |output_idx| {
            for (self.base.sorted) |idx| {
                const module_idx = self.moduleIdxFromNodeIdx(idx);

                var in_bufs_at: usize = 0;
                var edge_iter = self.base.graph.edgesDirected(idx, .Incoming);
                while (edge_iter.next()) |ref| {
                    const in_buf_idx = self.moduleIdxFromNodeIdx(ref.edge.start_node);
                    self.base.temp_in_bufs.items[in_bufs_at] = .{
                        .id = ref.edge.weight,
                        .buf = &self.base.modules.items[in_buf_idx].buffer,
                    };
                    in_bufs_at += 1;
                }

                var out_buf = &self.base.modules.items[module_idx].buffer;
                self.base.modules.items[module_idx].module.compute(
                    ctx,
                    self.base.temp_in_bufs.items[0..in_bufs_at],
                    out_buf,
                );
            }

            std.mem.copy(f32, out, self.base.modules.items[output_idx].buffer[0..ctx.frame_len]);
        } else {
            std.mem.set(f32, out, 0.);
        }
    }
};

// this needs to keep track of removals,
// so it can deinit removed modules after theve been swapped out
// module interface needs deinit (rust does this with Box<> but secretly)
pub const Controller = struct {
    const Self = @This();

    allocator: *Allocator,

    base: AudioGraphBase,
    max_inputs: usize,

    tx: EventChannel(AudioGraphBase).Sender,
    rx: Channel(AudioGraphBase).Receiver,

    pub fn init(
        allocator: *Allocator,
        channel: *Channel(AudioGraphBase),
        event_channel: *EventChannel(AudioGraphBase),
    ) Self {
        return .{
            .allocator = allocator,
            .base = AudioGraphBase.init(allocator),
            .max_inputs = 0,
            .tx = event_channel.makeSender(),
            .rx = channel.makeReceiver(),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.base.graph.nodes.items) |*node| {
            if (node.in_use) {
                self.base.modules.items[node.weight].module.deinit();
            }
        }
        self.base.deinit();
    }

    //;

    fn updateMaxInputs(self: *Self) void {
        self.max_inputs = 0;
        for (self.base.graph.nodes) |node, idx| {
            if (node.in_use) {
                var input_ct = 0;
                var edge_iter = self.base.graph.edgesDirected(idx, .Incoming);
                while (edge_iter.next()) |_| : (input_ct += 1) {}
                if (input_ct > self.max_inputs) {
                    self.max_inputs = input_ct;
                }
            }
        }
    }

    // takes ownership of module
    // TODO handle not found errors? maybe not
    pub fn addModule(self: *Self, mod: Module) !NodeIndex {
        const id = self.base.modules.items.len;
        try self.base.modules.append(.{
            .module = mod,
            .buffer = [_]f32{0.} ** max_callback_len,
        });
        return try self.base.graph.addNode(id);
    }

    pub fn addEdge(
        self: *Self,
        source: NodeIndex,
        target: NodeIndex,
        input_number: usize,
    ) !EdgeIndex {
        const edge_idx = try self.base.graph.addEdge(source, target, input_number);
        var input_ct: usize = 0;
        var edge_iter = self.base.graph.edgesDirected(target, .Incoming);
        while (edge_iter.next()) |_| : (input_ct += 1) {}
        if (input_ct > self.max_inputs) {
            self.max_inputs = input_ct;
        }
        return edge_idx;
    }

    // TODO check removals work
    // remove by node id
    //   module id is just uzsed internally
    pub fn removeModule(self: *Self, node_idx: NodeIndex) void {
        const module_idx = self.base.graph.nodes.items[node_idx].weight;
        self.base.graph.removeNode(node_idx);
        self.removals.append(module_idx);
        self.updateMaxInputs();
    }

    pub fn removeEdge(self: *Self, edge_idx: EdgeIndex) void {
        self.base.graph.removeEdge(edge_idx);
    }

    pub fn setOutput(self: *Self, node_idx: NodeIndex) void {
        self.base.output = node_idx;
    }

    pub fn pushChanges(
        self: *Self,
        now: u64,
        workspace_allocator: *Allocator,
    ) !void {
        // TODO you have to clone here
        // this send here takes ownership
        // actual AudioGraphBase the controller started with is never sent to the other thread
        //   can be deinited normally when controller is deinited
        var to_send = try self.base.clone();

        try to_send.sort(workspace_allocator);
        try to_send.temp_in_bufs.ensureCapacity(self.max_inputs);
        // TODO do i really wana do this
        to_send.temp_in_bufs.items.len = self.max_inputs;

        // TODO theres an error here for if channel is full
        self.tx.send(now, to_send) catch unreachable;
    }

    pub fn frame(self: *Self) void {
        if (self.rx.tryRecv()) |*swap| {
            for (swap.removals.items) |module_idx| {
                var gm = swap.modules.orderedRemove(module_idx);
                gm.module.deinit();
            }
            // ??
            // TODO deinit and free and stuff
            // swap.deinit();
        }
    }
};
