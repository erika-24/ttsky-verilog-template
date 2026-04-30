import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


# Modes
MODE_VIEW    = 0b00
MODE_PLANT   = 0b01
MODE_WATER   = 0b10
MODE_HARVEST = 0b11

# Crops
CROP_WHEAT  = 0
CROP_CORN   = 1
CROP_CARROT = 2
CROP_TOMATO = 3


passed = 0
failed = 0


def pack_inputs(mode=0, field=0, crop=0, action=0, fulfill=0):
    """
    TinyFarm Tiny Tapeout input mapping:
      ui[1:0] = mode
      ui[3:2] = field
      ui[5:4] = crop
      ui[6]   = action
      ui[7]   = fulfill
    """
    return (
        (mode & 0x3)
        | ((field & 0x3) << 2)
        | ((crop & 0x3) << 4)
        | ((action & 0x1) << 6)
        | ((fulfill & 0x1) << 7)
    )


def check(dut, name, condition):
    global passed, failed
    if condition:
        passed += 1
        dut._log.info(f"GOOD: {name}")
    else:
        failed += 1
        dut._log.warning(f"NOT GOOD: {name}")


def get_core(dut):
    """
    Access internal TinyFarm RTL through the Tiny Tapeout wrapper.
    This is intended for RTL-level verification.
    """
    return dut.user_project.tinyfarm_inst


async def press_action(dut, mode, field, crop):
    dut.ui_in.value = pack_inputs(mode=mode, field=field, crop=crop, action=1)
    await ClockCycles(dut.clk, 3)
    dut.ui_in.value = pack_inputs(mode=mode, field=field, crop=crop, action=0)
    await ClockCycles(dut.clk, 3)


async def press_fulfill(dut):
    dut.ui_in.value = pack_inputs(fulfill=1)
    await ClockCycles(dut.clk, 3)
    dut.ui_in.value = pack_inputs()
    await ClockCycles(dut.clk, 3)


@cocotb.test()
async def test_project(dut):
    global passed, failed
    passed = 0
    failed = 0

    dut._log.info("Start TinyFarm self-checking cocotb test")

    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())  # 25 MHz

    # Initial values
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    await ClockCycles(dut.clk, 5)

    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    core = get_core(dut)

    # TEST 1: Reset state
    check(dut, "Reset clears score", int(core.score.value) == 0)
    check(dut, "Reset clears inventory", int(core.inventory_o.value) == 0)

    check(
        dut,
        "Reset clears field 0",
        int(core.field_valid[0].value) == 0
        and int(core.field_ready[0].value) == 0
        and int(core.field_timer[0].value) == 0,
    )

    check(dut, "Reset creates valid order quantity", int(core.order_qty.value) != 0)

    # TEST 2: Plant wheat in field 0
    await press_action(dut, MODE_PLANT, 0, CROP_WHEAT)

    check(dut, "Plant marks field valid", int(core.field_valid[0].value) == 1)
    check(dut, "Plant sets correct crop type", int(core.field_crop[0].value) == CROP_WHEAT)
    check(dut, "Plant loads correct wheat timer", int(core.field_timer[0].value) == 3)
    check(dut, "Plant clears ready flag", int(core.field_ready[0].value) == 0)

    # TEST 3: Planting on occupied field does not overwrite crop
    crop_before = int(core.field_crop[0].value)
    timer_before = int(core.field_timer[0].value)

    await press_action(dut, MODE_PLANT, 0, CROP_CORN)

    check(dut, "Plant on occupied field does not overwrite crop",
          int(core.field_crop[0].value) == crop_before)

    timer_after = int(core.field_timer[0].value)
    check(dut, "Plant on occupied field does not reload timer",
        timer_after <= timer_before)

    # TEST 4: Watering reduces timer
    timer_before = int(core.field_timer[0].value)

    await press_action(dut, MODE_WATER, 0, CROP_WHEAT)

    timer_after = int(core.field_timer[0].value)

    check(
        dut,
        "Water decrements timer by 1",
        ((timer_before > 1) and (timer_after == timer_before - 1))
        or ((timer_before == 1) and (timer_after == 0)),
    )

    check(dut, "Water does not prematurely set ready", int(core.field_ready[0].value) == 0)

    # TEST 5: Game tick grows crop to ready
    await ClockCycles(dut.clk, 25)

    check(dut, "Game tick continues decrement",
          int(core.field_timer[0].value) <= 1)

    await ClockCycles(dut.clk, 25)

    check(
        dut,
        "Field becomes ready when timer reaches zero",
        int(core.field_ready[0].value) == 1
        and int(core.field_timer[0].value) == 0,
    )

    # TEST 6: Harvest ready crop
    await press_action(dut, MODE_HARVEST, 0, CROP_WHEAT)

    check(dut, "Harvest increments wheat inventory", int(core.inventory[0].value) == 1)
    check(dut, "Harvest clears field valid", int(core.field_valid[0].value) == 0)
    check(dut, "Harvest clears ready flag", int(core.field_ready[0].value) == 0)

    # TEST 7: Harvest on empty field has no effect
    await press_action(dut, MODE_HARVEST, 0, CROP_WHEAT)

    check(dut, "Harvest on empty field does not increment inventory",
          int(core.inventory[0].value) == 1)

    # TEST 8: Successful fulfill
    # Force deterministic order internally for RTL test:
    # order = 1 wheat
    core.order_crop.value = CROP_WHEAT
    core.order_qty.value = 1
    core.order_timer.value = 8

    await ClockCycles(dut.clk, 2)
    await press_fulfill(dut)

    check(dut, "Fulfill decrements inventory", int(core.inventory[0].value) == 0)
    check(dut, "Fulfill increments score", int(core.score.value) == 1)

    # TEST 9: Failed fulfill
    core.order_crop.value = CROP_CORN
    core.order_qty.value = 2
    core.order_timer.value = 8

    await ClockCycles(dut.clk, 2)
    await press_fulfill(dut)

    check(dut, "Failed fulfill does not change score", int(core.score.value) == 1)
    check(dut, "Failed fulfill does not create negative inventory",
          int(core.inventory[1].value) == 0)

    # Output sanity checks
    check(dut, "uo_out is resolvable", dut.uo_out.value.is_resolvable)
    check(dut, "uio_out is tied to zero", int(dut.uio_out.value) == 0)
    check(dut, "uio_oe is tied to zero", int(dut.uio_oe.value) == 0)

    dut._log.info("--------------------------------------------------")
    dut._log.info(f"TEST SUMMARY: {passed} passed, {failed} failed")
    dut._log.info("--------------------------------------------------")

    assert failed == 0, f"TinyFarm self-check failed: {passed} passed, {failed} failed"