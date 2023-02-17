#!/usr/bin/python3
#
# Calculate stats over array of numbers (read from stdin)
# Outpus Num Min Med Avg Pct% Max
# The percentile can be specified on the command line (-p)
# The number of digits as well (-d)
#
# (c) Kurt Garloff <kurt@garloff.de>
# SPDX-License-Identifier: CC-BY-SA-4.0

import sys

prec = 1e-5


def stats(arr, pct=95, digi=2, machine=False):
    aln = len(arr)
    arr.sort()
    middle = int(aln / 2)
    if aln % 2:
        med = arr[middle]
    else:
        med = (arr[middle - 1] + arr[middle]) / 2.0
    avg = sum(arr) / aln
    pctpos = (aln - 1) * pct / 100
    pctposi = int(pctpos + prec)
    wgt = pctpos - pctposi
    if abs(wgt) < prec:
        pctl = arr[pctposi]
    else:
        pctl = arr[pctposi + 1] * wgt + arr[pctposi] * (1 - wgt)
    fmt = ".%if" % digi
    if abs(pct - int(pct)) == 0:
        pctfmt = "%i%%" % pct
    else:
        pctfmt = "%.2f%%" % pct
    if machine:
        fstr = "{}|{:%s}|{:%s}|{:%s}|{:%s}|{:%s}" % (fmt, fmt, fmt, fmt, fmt)
    else:
        if pct > 50:
            fstr = "Num {0} Min {1:%s} Med {2:%s} Avg {3:%s} %s {4:%s} Max {5:%s}" % (
                fmt,
                fmt,
                fmt,
                pctfmt,
                fmt,
                fmt,
            )
        else:
            fstr = "Num {0} Min {1:%s} %s {4:%s} Med {2:%s} Avg {3:%s} Max {5:%s}" % (
                fmt,
                pctfmt,
                fmt,
                fmt,
                fmt,
                fmt,
            )
    # print(fstr)
    print(fstr.format(aln, arr[0], med, avg, pctl, arr[aln - 1]))


def main(argv):
    pct = 95
    dig = 2
    machine = False
    optidx = 0
    while optidx < len(argv):
        if argv[optidx] == "-p":
            optidx += 1
            pct = float(argv[optidx])
        elif argv[optidx] == "-d":
            optidx += 1
            dig = int(argv[optidx])
        elif argv[optidx] == "-m":
            machine = True
        else:
            print(
                'Error: Unknown option "%s". Usage stats.py [-p pct] [-d dig] [-m] < data'
                % argv[optidx]
            )
            sys.exit(1)
        optidx += 1

    arr = list(map(lambda x: float(x), sys.stdin.read().rstrip("\n").split(" ")))
    stats(arr, pct, dig, machine)


if __name__ == "__main__":
    main(sys.argv[1:])
