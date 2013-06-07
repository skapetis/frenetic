Chapter 1: Repeater
====================

### Introduction to OpenFlow

In a basic SDN, all switches connect to a centralized controller
machine. The controller thus has a global view of network and can
program all switches to implement a unified, network-wide policy.
To program a switch, the controller uses a standard protocol, such as
OpenFlow.

A switch processes packets using a _flow table_, which is a list of
prioritized rules.  Each rule has four components:

- A _pattern_ to match packets' headers,

- A _list of actions_ that is applied to matching packets,

- A _priority_ that is used to choose between rules that have
  overlapping patterns, and

- A _packet counter_ and a _byte counter_ that record the number
  of packets and bytes that have matched the rule.

For example, consider the following flow table:

<table>
<tr>
  <th>Priority</th><th>Pattern</th><th>Action List</th> <th>Counter (bytes)</th>
</tr>
<tr>
  <td>50</td><td>ICMP</td><td></td><td>50</td>
</tr>
  <td>40</td><td>TCP</td><td>forward 2, forward 5</td><td>700</td>
</tr>
<tr>
  <td>30</td><td>UDP</td><td>controller</td><td>50</td>
</tr>
<tr>
  <td>20</td><td>ICMP</td><td>forward 2</td><td>0</td>
</table>

We can understand the table by interpreting the patterns and actions
in priority-order:

1. The highest priority rule drops all ICMP packets (because it has an
   empty action list).

2. The next rule sends TCP packets out of ports 2 and 5 (i.e., it
   creates two copies).

3. The next rule sends UDP traffic to the special controller port (see
   below).

4. The final rule matches ICMP traffic. However, since it is
   fully-shadowed by the first rule, it will never be reached. (Fully
   shadowed rules can usually be safely eliminated.)

The third rule is notable, because it _sends packets to the
controller_. Since the controller runs an arbitrary program (an OCaml
program, in our case), you can write essentially any packet-processing
function you desire by sending packets to the controller.

For example, you could &mdash; in theory &mdash; do deep-packet
inspection by sending packets to the controller. Of course, this is
much slower than processing packets on the switch itself. Therefore, a
controller typically uses the flow table to implement the intended
packet-processing function efficiently.

## Warmup: Programming a Repeater

As a warmup exercise, you will build a repeater: a switch that
forwards incoming packets on all other ports. You will do so in two
steps:

- First, you will leave the flow table empty, so all packets are
  diverted to the controller for processing. At the controller, you can
  use general programming techniques to express any policy you desire.

- After you complete and test the controller's packet-processing function,
  you will add rules to the flow table to implement the packet-processing
  function on the switch itself.

> This two-step exercise may seem contrived for a simple repeater. But, we
> will quickly escalate to programs that are tricky to implement
> efficiently. For these programs, the first naive implementation will
> serve as a reference implementation to help you determine if your
> efficient implementation is correct. We will also witness some corner
> cases where it is necessary to process packets on both the controller
> and switches. So, you do need both implementations.

### Exercise 1: A Naive Repeater

In this part, you will only write the `packet_in` function for the repeater,
thereby processing all packets at the controller.

Use [Repeater.ml](ox-tutorial-code/Repeater.ml) as a starting point. This file and
the entire tutorial is included with the tutorial VM.  Open a terminal
and type:

```shell
$ cd src/frenetic/guide/ox-tutorial-code
```

We recommend working in this directory. It has a Makefile that links
to the Ox libraries for you.

#### Programming Task

[Repeater.ml](ox-tutorial-code/Repeater.ml) has a `packet_in` function
that just drops all packets. This is obviously wrong. To be a
repeater, it has to send it out of all ports (excluding the input
port). This is easier than it sounds, because you can do it with just
one OpenFlow action.


Find the right action in the Ox manual (it is in the [OpenFlow_Core]
module) and use it.

<h4 id="compiling">Compiling your Controller</h4>

To build your controller, run the following command in the
`ox-tutorial-code` directory:

```shell
  $ make Repeater.d.byte
```

> The file extension indicates that it is a bytecode, debug build.  You
> can use `make foo.d.byte` to compile any `foo.ml` file in this
> directory.

If compilation succeeds, you should see output akin to this:

```
ocamlbuild -use-ocamlfind -cflag -ppopt -cflag -lwt-debug Repeater.d.byte
Finished, 4 targets (0 cached) in 00:00:00.
```

#### Testing your Controller

You can test your controller using Mininet, which is included in the
tutorial VM. Mininet runs a virtual network on your computer,
isolating each virtual host in a Linux container. To test the
repeater, use Mininet to create a network with one switch and three
hosts and have them ping each other:

- Start your controller

  ```
  $ ./Repeater.d.byte
  ```

  It should print `[Ox] Controller launching...`


- Start Mininet in a separate terminal window:

  ```
  $ sudo mn --controller=remote --topo=single,3 --mac
  ```

  A brief explanation of the flags:

  * `topo=single` creates a network with one switch and three hosts.

  * `--mac` sets the hosts mac addresses to `1`, `2`, and `3` (instead
    of a random number). This makes debugging a lot easier.

  * `--controller=remote` directs the switches to connect to your controller
    (instead of using a default controller that is built into Mininet).

  
- After Mininet launches, your controller should print
  `[Ox_Controller] switch 1 connected`.

  Mininet will print the network topology, then drop you into the Mininet
  prompt:

  `mininet>`

- From the Mininet prompt, you can make your hosts ping each other:

  ```
  mininet> h1 ping h2
  mininet> h2 ping h3
  ...
  ```
  
  Pinging should always succeed. In addition, if your controller
  calls `printf` in its packet-in function, you will see the controller
  receiving all pings (and other traffic, such as ARP).

This repeater is functionall correct, but laughably inefficient.
  
### Exercise 2: An Efficient Repeater

Processing all packets at the controller is very inefficient.
You will now add rules to the switch _flow table_ to have the switch
process packets itself.

For this part, continue building on the naive repeater you wrote above.

> Build on its [solution file](ox-tutorial-code/Sol_Repeater1.ml)
> if necessary.

#### Programming Task

You will now fill in the `switch_connected` handler in your program.
Use the following as a template:

```ocaml
let switch_connected (sw : switchId) : unit =
  Printf.printf "Switch %Ld connected.\n%!" sw;
  send_flow_mod sw 1l (FlowMod.add_flow priority pattern action_list)
```

This function uses [send_flow_mod] to add a new rule to
the flow table. Your task is to fill in `priority`, `pattern`, and
`action_list`.

- `pattern` is an OpenFlow [pattern] for matching packets.  Since your
   repeater matches all packets, you can simply use [match_all].
   (We cover patterns in detail later.)

- `priority` is a 16-bit priority for the rule. Since you just have one
  rule, the priority you pick is not relevant.

- For `action_list`, you must apply the same actions you did in your
  `packet_in` function. (If not, switch and controller will be
  inconsistent.)

#### Building and Testing Your Controller

You can build and test this extended repeater in exactly the same way
you tested the last. However, during testing, the controller should not
receive any packets itself.

- Build and start the controller:

  ```shell
  $ make Repeater.byte
  $ ./Repeater.d.byte
  ```

- In a separate terminal, start Mininet:

  ```
  $ sudo mn --controller=remote --topo=single,3 --mac
  ```

- From the Mininet prompt, try a ping:

  ```
  mininet> h1 ping h2
  ```

  The pings should succeed, but the controller won't receive any
  packets (keep a `printf` in the `packet_in` function to observe
  packets reaching the controller).

### Why Keep the Controller Function?

You now have two implementations of the repeater: the `packet_in`
function on the controller and the flow table on the switch.  Since
the switch is so much faster, why keep the `packet_in` function at
all?

It turns out that there are still situations where the `packet_in`
function is necessary. We'll try to create such a situation artificially:

- Shutdown the repeater (`Ctrl+C`)

- In mininet, send a stream of high-frequency pings:

  ```
  mininet> h1 ping -i 0.001 h2
  ```

- Launch the repeater again:

  ```
  $ ./Repeater.d.byte
  ```

It is very likely that a few packets will get sent to the controller,
and here's why.  When you launch the controller and the switch
re-connects, your controller sends two messages:

- First, Ox automatically sends a message to _delete all flows_.
  In general, we don't know the state of the flow table when a switch
  connects, so we need to start with a clean slate.

  > TODO(arjun): NATE FOSTER and LAURENT. Forward reference?

- Next, Ox sends the _add flow_ message that you wrote.

In the interval between these two messages, the flow table is empty,
thus packets get diverted to the controller. More broadly, whenever
the switch is configured for the first time, or re-configured to
implement a policy change, you may see packets at the controller.

[Ch2]: 02-OxRepeater.md
[Ch3]: 03-OxFirewall.md
[Ch4]: 04-OxMonitor.md
[Ch5]: 05-OxLearning.md
[Ch6]: 06-NetCoreIntroduction.md
[Ch7]: 07-NetCoreComposition.md
[Ch8]: 08-DynamicNetCore.md

[Action]: http://frenetic-lang.github.io/frenetic/docs/OpenFlow0x01.Action.html

[PacketIn]: http://frenetic-lang.github.io/frenetic/docs/OpenFlow0x01.PacketIn.html

[PacketOut]: http://frenetic-lang.github.io/frenetic/docs/OpenFlow0x01.PacketOut.html

[OxPlatform]: http://frenetic-lang.github.io/frenetic/docs/Ox_Controller.OxPlatform.html

[Match]: http://frenetic-lang.github.io/frenetic/docs/OpenFlow0x01.Match.html

[Packet]: http://frenetic-lang.github.io/frenetic/docs/Packet.html