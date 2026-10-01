# frozen_string_literal: true

class Money
  class ControlledRounding
    # A small directed graph with integer capacities and exact (rational)
    # edge costs, solved with successive shortest augmenting paths.
    #
    # @api private
    class FlowNetwork
      Edge = Struct.new(:to, :rev, :cap, :cost)

      def initialize(size)
        @graph = Array.new(size) { [] }
      end

      # Adds a forward edge and its residual reverse edge; returns the
      # forward edge so callers can inspect its remaining capacity.
      def add_edge(from, to, cap, cost)
        forward = Edge.new(to, @graph[to].length, cap, cost)
        backward = Edge.new(from, @graph[from].length, 0, -cost)
        @graph[from] << forward
        @graph[to] << backward
        forward
      end

      # Augments flow from source to sink along shortest paths until the
      # target flow is reached or the network is exhausted. Returns the
      # flow actually pushed.
      def min_cost_flow(source, sink, target)
        flow = 0
        while flow < target && (path = shortest_path(source, sink))
          amount = target - flow
          path.each { |node, index| amount = [amount, @graph[node][index].cap].min }
          path.each do |node, index|
            edge = @graph[node][index]
            edge.cap -= amount
            @graph[edge.to][edge.rev].cap += amount
          end
          flow += amount
        end
        flow
      end

      # Nodes reachable from the given node through edges with remaining
      # capacity; used to derive a min-cut certificate of infeasibility.
      def reachable_from(source)
        seen = Array.new(@graph.length, false)
        seen[source] = true
        stack = [source]
        until stack.empty?
          node = stack.pop
          @graph[node].each do |edge|
            next if edge.cap <= 0 || seen[edge.to]
            seen[edge.to] = true
            stack << edge.to
          end
        end
        seen
      end

      private

      # Shortest path from source to sink in the residual graph (SPFA, which
      # tolerates the negative edge costs of rounding up vs. down).
      def shortest_path(source, sink)
        dist = Array.new(@graph.length)
        prev = Array.new(@graph.length)
        in_queue = Array.new(@graph.length, false)
        dist[source] = 0
        queue = [source]
        in_queue[source] = true
        until queue.empty?
          node = queue.shift
          in_queue[node] = false
          @graph[node].each_with_index do |edge, index|
            next if edge.cap <= 0
            candidate = dist[node] + edge.cost
            next if dist[edge.to] && candidate >= dist[edge.to]
            dist[edge.to] = candidate
            prev[edge.to] = [node, index]
            unless in_queue[edge.to]
              queue << edge.to
              in_queue[edge.to] = true
            end
          end
        end
        return nil if dist[sink].nil?
        path = []
        node = sink
        until node == source
          from, index = prev[node]
          path << [from, index]
          node = from
        end
        path.reverse
      end
    end
  end
end
