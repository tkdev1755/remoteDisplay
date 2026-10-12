# linkbench — what can the Thunderbolt link actually carry?

A small test battery to measure the IP-over-Thunderbolt link between the Mac
(sender) and the iMac (receiver), first with generic tools, then with traffic
shaped like remoteDisplay's.

## What it measures

1. **Link facts** (`linkinfo.sh`, on both machines): negotiated Thunderbolt
   speed, MTU, socket buffer limits, CPU governor.
2. **Raw throughput** (`iperf3`): TCP with 1 and 4 streams, both directions,
   then a UDP sweep from 2 to 25 Gbit/s with 65,000-byte datagrams, to find the
   rate where packets start getting lost.
3. **remoteDisplay-like traffic** (`framebench`): whole frames cut into UDP
   chunks and sent in one burst per frame, like the real sender. For each frame
   size (4K and 5K, NV12 and BC7) and frame rate (60, 90 and 120 fps), it reports:
   - **delivered %**: frames that arrived complete;
   - **latency**: from the start of a frame's burst until the receiver's
     acknowledgement comes back (sender clock only, no clock sync needed);
   - **burst**: first chunk → last chunk, on the receiver's clock;
   - **goodput**: useful bits of complete frames per second.

   It also checks how the datagram size (4,000 to 48,000 bytes) affects today's frames.

## Running it

**On the iMac (receiver)** — stop remoteDisplay first, so it doesn't compete
for the CPU and the link:

```bash
sudo systemctl stop rd-helper
cc -O2 -o framebench framebench.c -lm
./linkinfo.sh > linkinfo_receiver.txt
iperf3 -s &              # needs: sudo apt-get install iperf3
./framebench recv        # UDP :6000, Ctrl-C to stop
```

If a firewall is active, allow TCP/UDP 5201 (iperf3) and UDP 6000 (framebench).

**On the Mac (sender):**

```bash
sudo sysctl -w net.inet.udp.maxdgram=65535   # macOS refuses large datagrams by default
./run_suite.sh 10.0.0.1                       # ~5 minutes with 10 s per test
```

Results land in `results/<date>/`: the raw outputs, `summary_iperf.csv`,
`summary_framebench.csv`, and a summary printed at the end.

Afterwards, restart remoteDisplay on the iMac: `sudo systemctl start rd-helper`.

## Reading the results

- **The negotiated speed is not the usable throughput.** A 40 Gb/s
  Thunderbolt link carries less as IP traffic: the network driver and the CPU
  usually limit it first. The iperf3 numbers are the real ceiling.
- **The UDP sweep** shows the highest rate with near-zero loss. If it stays
  well above 7 Gbit/s, 5K in BC7 at 60 fps fits; above 10.6 Gbit/s, even
  uncompressed 5K would.
- **framebench at 60 fps** is the realistic case: delivered % should be
  100, and the burst time is the part of the display latency spent on the wire.
- **framebench at 90 and 120 fps** shows the headroom left for each format.
- **The chunk-size runs** show whether large datagrams still matter on this
  link (they did with the default 1,500-byte MTU).
- A single run is a snapshot: run the suite two or three times before drawing
  conclusions.
