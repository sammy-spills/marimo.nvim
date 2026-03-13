import marimo

__generated_with = "0.20.4"
app = marimo.App(width="full")


@app.cell
def _():
    import marimo as mo

    return mo


@app.cell
def _():
    print("Testing")
    return


@app.cell
def _():
    foofoofoofoo = 1
    barbarbarbar = 2
    bazbazbazbaz = 3
    testtesttest = 5
    blahblahblahblahblah = 6

    return (
        foofoofoofoo,
        barbarbarbar,
        bazbazbazbaz,
        testtesttest,
        blahblahblahblahblah,
    )


@app.cell
def _(
    foofoofoofoo,
    barbarbarbar,
    bazbazbazbaz,
    testtesttest,
    blahblahblahblahblah,
    foofoofoofoo,
):
    print("That worked")
    return
